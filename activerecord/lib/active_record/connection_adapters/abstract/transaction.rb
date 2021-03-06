module ActiveRecord
  module ConnectionAdapters
    class Transaction #:nodoc:
      attr_reader :connection

      def initialize(connection)
        @connection = connection
      end
    end

    class ClosedTransaction < Transaction #:nodoc:
      def number
        0
      end

      def begin
        RealTransaction.new(connection, self)
      end

      def closed?
        true
      end

      def open?
        false
      end

      def joinable?
        false
      end

      # This is a noop when there are no open transactions
      def add_record(record)
      end
    end

    class OpenTransaction < Transaction #:nodoc:
      attr_reader :parent, :records
      attr_writer :joinable

      def initialize(connection, parent)
        super connection

        @parent    = parent
        @records   = []
        @finishing = false
        @joinable  = true
      end

      # This state is necesarry so that we correctly handle stuff that might
      # happen in a commit/rollback. But it's kinda distasteful. Maybe we can
      # find a better way to structure it in the future.
      def finishing?
        @finishing
      end

      def joinable?
        @joinable && !finishing?
      end

      def number
        if finishing?
          parent.number
        else
          parent.number + 1
        end
      end

      def begin
        if finishing?
          parent.begin
        else
          SavepointTransaction.new(connection, self)
        end
      end

      def rollback
        @finishing = true
        perform_rollback
        parent
      end

      def commit
        @finishing = true
        perform_commit
        parent
      end

      def add_record(record)
        records << record
      end

      def rollback_records
        records.uniq.each do |record|
          begin
            record.rolledback!(parent.closed?)
          rescue => e
            record.logger.error(e) if record.respond_to?(:logger) && record.logger
          end
        end
      end

      def commit_records
        records.uniq.each do |record|
          begin
            record.committed!
          rescue => e
            record.logger.error(e) if record.respond_to?(:logger) && record.logger
          end
        end
      end

      def closed?
        false
      end

      def open?
        true
      end
    end

    class RealTransaction < OpenTransaction #:nodoc:
      def initialize(connection, parent)
        super
        connection.begin_db_transaction
      end

      def perform_rollback
        connection.rollback_db_transaction
        rollback_records
      end

      def perform_commit
        connection.commit_db_transaction
        commit_records
      end
    end

    class SavepointTransaction < OpenTransaction #:nodoc:
      def initialize(connection, parent)
        super
        connection.create_savepoint
      end

      def perform_rollback
        connection.rollback_to_savepoint
        rollback_records
      end

      def perform_commit
        connection.release_savepoint
        records.each { |r| parent.add_record(r) }
      end
    end
  end
end
