# Migration specs run a gem migration for real, then rely on the per-example
# transaction to undo it. That only works on SQLite, whose DDL is
# transactional. On PostgreSQL (the CI `test (postgres)` job) the migrations
# build and drop indexes CONCURRENTLY, which PG refuses inside a transaction.
#
# So on PG a group that includes this module runs outside the transaction, and
# after each example it migrates the described migration back up (they are all
# idempotent) and empties every table the example wrote to.
module MigrationSpecSupport
  def self.included(group)
    return unless ActiveRecord::Base.connection.adapter_name.match?(/postg/i)

    group.use_transactional_tests = false
    group.after do
      ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
      connection = ActiveRecord::Base.connection
      tables = connection.tables - %w[schema_migrations ar_internal_metadata]
      connection.execute("TRUNCATE #{tables.map { |t| connection.quote_table_name(t) }.join(", ")} RESTART IDENTITY CASCADE")
    end
  end

  # PG normalises a partial index predicate (parentheses); SQLite keeps it as
  # written. Compare without them.
  def normalized_where(index)
    index.where.to_s.delete("()")
  end
end
