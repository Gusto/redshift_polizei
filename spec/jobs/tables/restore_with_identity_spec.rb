require_relative '../../spec_helper'

describe Jobs::RestoreJob do

  #
  # Runs a RestoreJob with the specified options and returns the job run.
  #
  def run_restore(options={})
    return Jobs::RestoreJob.enqueue('UserId',
                                    {
                                        db: {
                                            connection_id: $connection_id,
                                            username: @config[:rs_user],
                                            password: @config[:rs_password],
                                            schema: @config[:schema],
                                            table: nil
                                        },
                                        s3: {
                                            access_key_id: @config[:aws_access_key_id],
                                            secret_access_key: @config[:aws_secret_access_key],
                                            bucket: @config[:bucket],
                                            prefix: nil
                                        },
                                        copy: {
                                            gzip: false,
                                            removequotes: true,
                                            escape: true,
                                            null_as: 'NULL'
                                        },
                                        mail: {nomailer: true}
                                    }.deep_merge(options))
  end

  it 'should fail if ddl file does not exist' do
    @bucket.object(@ddl_file).delete
    r = run_restore({db: {table: @table}, s3: {prefix: @archive_prefix}})
    expect(r.failed?).to eq(true)
    expect(r.error).to eq("S3 ddl_file #{@config[:bucket]}/#{@archive_prefix}ddl does not exist!")
  end

  it 'should fail if manifest file does not exist' do
    @bucket.object(@manifest_file).delete
    r = run_restore({db: {table: @table}, s3: {prefix: @archive_prefix}})
    expect(r.failed?).to eq(true)
    expect(r.error).to eq("S3 manifest_file #{@config[:bucket]}/#{@manifest_file} does not exist!")
  end

  it 'should fail if ddl file does not contain valid DDL' do
    ddl_text = <<-TEXT
      CREATE TABLE "#{@schema}"."#{@table}FAKE"(id INT, txt VARCHAR);
    TEXT
    @bucket.object(@ddl_file).put(body: ddl_text)
    r = run_restore({db: {table: @table}, s3: {prefix: @archive_prefix}})
    expect(r.failed?).to eq(true)
    expect(r.error).to eq("S3 ddl_file #{@config[:bucket]}/#{@ddl_file} must contain a single valid CREATE TABLE statement!")
  end

  it 'should properly restore a table' do
    # RestoreJob should succeed.
    r = run_restore({db: {table: @table}, s3: {prefix: @archive_prefix}})
    expect(r.failed?).to(eq(false), "Error: #{r.error}")
    expect(r.result['schema']).to eq(@schema)
    expect(r.result['table']).to eq(@table)

    # Ensure restored table exists in Redshift.
    # Ensure redshift table was dropped.
    res = $conn.exec("SELECT * FROM information_schema.tables WHERE table_schema = '#{@schema}' AND table_name = '#{@table}'")
    expect(res.ntuples).to eq(1)
    # Ensure restored table holds the archived data.
    res = $conn.exec("SELECT * FROM #{@full_table_name} ORDER BY id")
    expect(res.ntuples).to eq(4)
    expect(res[0]['id']).to eq('0')
    expect(res[0]['some_int']).to eq('3')
    expect(res[0]['txt']).to eq('hello')
    expect(res[1]['id']).to eq('1')
    expect(res[1]['some_int']).to eq('2')
    expect(res[1]['txt']).to eq('privyet')
    expect(res[2]['id']).to eq('2')
    expect(res[2]['some_int']).to eq('1')
    expect(res[2]['txt']).to be_nil
    expect(res[3]['id']).to eq('3')
    expect(res[3]['some_int']).to eq('0')
    expect(res[3]['txt']).to eq('|')

    # Ensure TableArchive entry was destroyed.
    expect(Models::TableArchive.find_by(schema_name: @schema, table_name: @table)).to be_nil
  end

  it 'should restore permissions correctly' do
    r = run_restore({db: {table: @table}, s3: {prefix: @archive_prefix}})
    expect(r.failed?).to(eq(false), "Error: #{r.error}")
    Jobs::Permissions::Update.run(1, schema_name: @schema, table_name: @table)
    table = Models::Table.find_by!(schema: Models::Schema.find_by!(name: @schema), name: @table)
    expect(table.owner.name).to eq($test_user)
    expect(Models::Permission.where(declared: true, dbobject: table).size).to eq(3)
    gperm = Models::Permission.find_by!(declared: true, dbobject: table, entity: Models::DatabaseGroup.find_by!(name: $test_group))
    uperm = Models::Permission.find_by!(declared: true, dbobject: table, entity: Models::DatabaseUser.find_by!(name: $conn.user))

    expect(gperm.has_select).to eq(false)
    expect(gperm.has_insert).to eq(true)
    expect(gperm.has_update).to eq(true)
    expect(gperm.has_delete).to eq(true)
    expect(gperm.has_references).to eq(false)
    expect(uperm.has_select).to eq(true)
    expect(uperm.has_insert).to eq(false)
    expect(uperm.has_update).to eq(false)
    expect(uperm.has_delete).to eq(false)
    expect(uperm.has_references).to eq(true)
  end

  before(:each) do
    @schema = @config[:schema]
    @table = "restore_test_#{Time.now.to_i}_#{rand(1024)}"
    @full_table_name = "#{@schema}.#{@table}"

    # Write sample ddl, manifest, and data files to S3.
    @bucket = Aws::S3::Bucket.new(@config[:bucket])
    @archive_prefix = "test/#{@full_table_name}"
    @ddl_file = "#{@archive_prefix}ddl"
    ddl_text = <<-TEXT
      CREATE TABLE "#{@schema}"."#{@table}"(id INT IDENTITY(0,1), some_int INT, txt VARCHAR);
    TEXT
    @bucket.object(@ddl_file).put(body: ddl_text)
    @perms_file = "#{@archive_prefix}permissions.sql"
    perms_text = <<-SQL
ALTER TABLE "#{@schema}"."#{@table}" OWNER TO "#{$test_user}";
GRANT INSERT, UPDATE, DELETE ON "#{@schema}"."#{@table}" TO GROUP "#{$test_group}";
GRANT SELECT, REFERENCES ON "#{@schema}"."#{@table}" TO "#{$conn.user}"
SQL
    @bucket.object(@perms_file).put(body: perms_text)
    @data_file= "#{@archive_prefix}-0000_part_00"
    data_text = <<-TEXT
"0"|"3"|"hello"
"1"|"2"|"privyet"
"2"|"1"|"NULL"
"3"|"0"|"|"
  TEXT
    # data_text = "0|hello\n1|privyet\n|"
    @bucket.object(@data_file).put(body: data_text)
    @manifest_file = "#{@archive_prefix}manifest"
    manifest_text = <<-JSON
      {"entries":[{"url":"s3://#{@config[:bucket]}/#{@data_file}"}]}
    JSON
    @bucket.object(@manifest_file).put(body: manifest_text)

    # Create TableArchive entry.
    table_archive = Models::TableArchive.create(schema_name: @schema, table_name: @table,
                                                archive_bucket: @config[:bucket],
                                                archive_prefix: @archive_prefix)
    table_archive.save
  end

  after(:each) do
    # Remove any TableArchive references.
    tbl = Models::TableArchive.find_by(schema_name: @schema, table_name: @table)
    tbl.destroy unless tbl.nil?
    # Remove extra TableReports references.
    tbl = Models::TableReport.find_by(schema_name: @schema, table_name: @table)
    tbl.destroy unless tbl.nil?
    # Drop test redshift table.
    $conn.exec("DROP TABLE IF EXISTS #{@full_table_name}")
    # Clean up S3 files.
    @bucket.objects(prefix: @archive_prefix).each(&:delete)
  end
end
