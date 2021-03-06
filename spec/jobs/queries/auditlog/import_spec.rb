require_relative '../../../spec_helper'

describe Jobs::Queries::AuditLog::Import do
  AUDITLOG_TEST_FILE = 'spec/248783370565_redshift_us-east-1_analytics-enc-dw-1_useractivitylog_2015-06-03T22:26.txt'

  before(:each) do
    Models::Query.destroy_all
    Models::AuditLogConfig.get.update!(last_update: 0)
  end

  it 'should import basic file' do
    expect do
      Jobs::Queries::AuditLog::Import.run(0, file: AUDITLOG_TEST_FILE)
    end.not_to raise_error
  end

  it 'should import basic query' do
    Jobs::Queries::AuditLog::Import.run(0, file: AUDITLOG_TEST_FILE)
    q = Models::Query.order('record_time asc').first
    expect(q.record_time).to eq(1427832000)
    expect(q.db).to eq('dev')
    expect(q.user).to eq('rdsdb')
    expect(q.pid).to eq(15312)
    expect(q.userid).to eq(1)
    expect(q.xid).to eq(834920)
    expect(q.query).to eq('SELECT 1')
    expect(q.logfile).to eq(AUDITLOG_TEST_FILE)
    expect(q.query_type).to eq(0)
  end

  it 'should import multi-line query' do
    Jobs::Queries::AuditLog::Import.run(0, file: AUDITLOG_TEST_FILE)
    q = Models::Query.order('record_time desc').first
    expect(q.record_time).to eq(1427832008)
    expect(q.db).to eq('amg')
    expect(q.user).to eq('polizei_bot')
    expect(q.pid).to eq(31260)
    expect(q.userid).to eq(137)
    expect(q.xid).to eq(834929)
    expect(q.query).to eq("select\n  1,\n  2\nfrom polizei")
    expect(q.logfile).to eq(AUDITLOG_TEST_FILE)
    expect(q.query_type).to eq(0)
  end

  it 'should import the same query from the same file only once' do
    Jobs::Queries::AuditLog::Import.run(0, file: AUDITLOG_TEST_FILE, max_import_size: 1)
    expect(Models::Query.count).to eq(2)
  end

  it 'should import from s3' do
    expect do
      Jobs::Queries::AuditLog::Import.run(0, just_one: true)
    end.not_to raise_error
    expect(Models::Query.count).not_to eq(0)
  end
end
