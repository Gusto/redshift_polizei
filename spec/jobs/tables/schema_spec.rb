require_relative '../../spec_helper'

describe Jobs::TableStructureExportJob do
  def schema_name
    PG::Connection.quote_ident(@config[:schema])
  end
  def new_table_name
    "polizei_schema_test_#{rand(1024)}"
  end

  def create_table(sql)
    RSPool.with { |c| c.exec(sql) }
  end

  def retrieve_schema(table_name, options={})
    RSPool.with do |c|
      begin
        aws_path = Jobs::TableStructureExportJob.run(1, 1, {
          schema_name: @config[:schema],
          table_name: table_name,
          nospacer: true,
          nomail: true
        }.merge(options))
        s3_obj = Aws::S3::Bucket.new(aws_path[:bucket]).object(aws_path[:key])
        return s3_obj.get.body.read
      ensure
        c.exec("DROP TABLE IF EXISTS #{@config[:schema]}.#{table_name}")
        s3_obj.delete unless s3_obj.nil?
      end
    end
  end

  it 'should create schema from basic table' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with multiple columns' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,\n\t\"id2\" integer NULL ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with varchar length-restricted column' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"txt\" character varying(42) NULL ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with restricted numeric column' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" numeric(4, 2) NULL ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with not null column' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NOT NULL ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema with default value column' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL DEFAULT 21 ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema with identity column' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL IDENTITY(42,21) ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema with encoded column' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE lzo\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with custom dist style' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw\n)\nDISTSTYLE key\nDISTKEY (\"id\")";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with unique constraint' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,\n\tUNIQUE (\"id\")\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with primary key' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NOT NULL ENCODE raw,\n\tPRIMARY KEY (\"id\")\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with foreign key' do
    begin
      table_name = new_table_name
      table_name2 = new_table_name
      table2_sql = "CREATE TABLE #{schema_name}.\"#{table_name2}\"(\n\t\"id\" integer NULL ENCODE raw,\n\tUNIQUE (\"id\")\n)\nDISTSTYLE all"
      create_table(table2_sql)
      table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,\n\tFOREIGN KEY (\"id\") REFERENCES #{schema_name}.\"#{table_name2}\" (\"id\")\n)\nDISTSTYLE all";
      create_table(table_sql)
      schema_sql = retrieve_schema(table_name)
      expect(schema_sql).to eq(table2_sql + "\n;" + table_sql + "\n;")
    ensure
      RSPool.with { |c| c.exec("DROP TABLE IF EXISTS #{@config[:schema]}.#{table_name2}") }
    end
  end

  it 'should create schema from basic table with more than 10 columns for ordering issues' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,"\
      "\n\t\"id2\" integer NULL ENCODE raw,\n\t\"id3\" integer NULL ENCODE raw,"\
      "\n\t\"id4\" integer NULL ENCODE raw,\n\t\"id5\" integer NULL ENCODE raw,"\
      "\n\t\"id6\" integer NULL ENCODE raw,\n\t\"id7\" integer NULL ENCODE raw,"\
      "\n\t\"id8\" integer NULL ENCODE raw,\n\t\"id9\" integer NULL ENCODE raw,"\
      "\n\t\"id10\" integer NULL ENCODE raw\n)\nDISTSTYLE all";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with single sort key' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw\n)\nDISTSTYLE all\nCOMPOUND SORTKEY (\"id\")";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with compound sort style' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,\n\t\"id2\" integer NULL ENCODE raw\n)\nDISTSTYLE all\nCOMPOUND SORTKEY (\"id\", \"id2\")";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with interleaved sort style' do
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,\n\t\"id2\" integer NULL ENCODE raw\n)\nDISTSTYLE all\nINTERLEAVED SORTKEY (\"id\", \"id2\")";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema from basic table with sort keys in right order' do
    # first direction
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,\n\t\"id2\" integer NULL ENCODE raw\n)\nDISTSTYLE all\nCOMPOUND SORTKEY (\"id\", \"id2\")";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
    # reversed direction
    table_name = new_table_name
    table_sql = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL ENCODE raw,\n\t\"id2\" integer NULL ENCODE raw\n)\nDISTSTYLE all\nCOMPOUND SORTKEY (\"id2\", \"id\")";
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name)
    expect(schema_sql).to eq(table_sql + "\n;")
  end

  it 'should create schema with no_column_encoding enabled' do
    table_name = new_table_name
    sql_prefix = "CREATE TABLE #{schema_name}.\"#{table_name}\"(\n\t\"id\" integer NULL"
    sql_suffix = "\n)\nDISTSTYLE all"
    table_sql = sql_prefix + " ENCODE lzo" + sql_suffix
    create_table(table_sql)
    schema_sql = retrieve_schema(table_name, {no_column_encoding: true})
    expect(schema_sql).to eq(sql_prefix + sql_suffix + "\n;")
  end
end
