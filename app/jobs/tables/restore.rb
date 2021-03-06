require_relative '../../main'

module Jobs
  ##
  # job restoring s3 data and a DDL into a Redshift table
  #
  # Please see `BaseJob` class documentation on how to run
  # any job using its general interface.
  #
  class RestoreJob < Desmond::BaseJobNoJobId
    include JobHelpers

    ##
    # runs a restore
    # see `BaseJob` for information on arguments except +options+.
    #
    # the following +options+ are required:
    # - db
    #   - schema: schema of table to restore
    #   - table: name of table to restore
    # - s3
    #   - access_key_id: s3 access key
    #   - secret_access_key: s3 secret key
    #   - bucket: bucket that holds data, ddl, and manifest files
    #   - prefix: filename prefix of relevant data, ddl, and manifest files
    #
    # the following +options+ are additionally supported:
    # - db
    #   - timeout: connection timeout to database
    # - copy: options for the Redshift COPY command
    #   - gzip: if true, will use the GZIP copy option
    #   - removequotes: if true, will use the REMOVEQUOTES copy option
    #   - escape: if true, will use the ESCAPE copy option
    #   - null_as: string to use for the NULL AS copy option
    #
    def execute(job_id, user_id, options={})
      fail 'No database options!' if options[:db].nil?
      fail 'No s3 options!' if options[:s3].nil?

      # s3 credentials for ddl and manifest files
      access_key = options[:s3][:access_key_id]
      secret_key = options[:s3][:secret_access_key]

      # construct full escaped table name
      schema_name = options[:db][:schema]
      fail 'Empty schema name!' if schema_name.nil? || schema_name.empty?
      table_name = options[:db][:table]
      fail 'Empty table name!' if table_name.nil? || table_name.empty?

      # file paths
      archive_bucket = options[:s3][:bucket]
      fail 'Empty archive_bucket!' if archive_bucket.nil? || archive_bucket.empty?
      archive_prefix = options[:s3][:prefix]
      fail 'Empty archive_prefix!' if archive_prefix.nil? || archive_prefix.empty?
      ddl_file = "#{archive_prefix}ddl"
      perms_file = "#{archive_prefix}permissions.sql"
      manifest_file = "#{archive_prefix}manifest"
      s3_bucket = Aws::S3::Bucket.new(archive_bucket)
      manifest_obj = s3_bucket.object(manifest_file)
      fail "S3 manifest_file #{archive_bucket}/#{manifest_file} does not exist!" unless manifest_obj.exists?

      # get the create table statement
      ddl_obj = s3_bucket.object(ddl_file)
      fail "S3 ddl_file #{archive_bucket}/#{ddl_file} does not exist!" unless ddl_obj.exists?
      # ensure create_table_statement is a single CREATE statement for the specified schema/table (for security)
      ddl_match = /CREATE TABLE "#{Regexp.quote(schema_name)}"\."#{Regexp.quote(table_name)}".*;/m.match(ddl_obj.get.body.read)
      fail "S3 ddl_file #{archive_bucket}/#{ddl_file} must contain a single valid CREATE TABLE statement!" if ddl_match.nil? || ddl_match.length != 1
      create_table_statement = ddl_match[0]

      # get the permissions statement
      perms_obj = s3_bucket.object(perms_file)
      fail "S3 perms_file #{archive_bucket}/#{perms_file} does not exist!" unless perms_obj.exists?
      permissions_statements = perms_obj.get.body.read

      # execute CREATE+COPY
      archive_bucket = Desmond::PGUtil.escape_string(archive_bucket)
      manifest_file = Desmond::PGUtil.escape_string(manifest_file)
      access_key = Desmond::PGUtil.escape_string(access_key)
      secret_key = Desmond::PGUtil.escape_string(secret_key)
      iam_role = Desmond::PGUtil.escape_string(GlobalConfig.polizei('aws_redshift_iam_role'))
      full_table_name = Desmond::PGUtil.get_escaped_table_name(options[:db], schema_name, table_name)
      copy_options = ''
      unless options[:copy].nil? || options[:copy].empty?
        copy_options += 'GZIP' if options[:copy][:gzip]
        copy_options += ' REMOVEQUOTES' if options[:copy][:removequotes]
        copy_options += ' ESCAPE' if options[:copy][:escape]
        unless options[:copy][:null_as].nil?
          copy_options += " NULL AS '#{Desmond::PGUtil.escape_string(options[:copy][:null_as])}'"
        end
      end
      # if we have custom iam keys we use these first
      if !access_key.nil? && !access_key.empty? && access_key != Aws.config[:access_key_id]
        credentials_str = "CREDENTIALS 'aws_access_key_id=#{access_key};aws_secret_access_key=#{secret_key}'"
      # if we have an iam role we use these second
      elsif !iam_role.nil? && !iam_role.empty?
        credentials_str = "IAM_ROLE '#{iam_role}'"
      # otherwise we use the default system iam keys
      else
        credentials_str = "CREDENTIALS 'aws_access_key_id=#{access_key};aws_secret_access_key=#{secret_key}'"
      end

      create_table_sql = "#{create_table_statement};"

      lock_sql = "LOCK #{full_table_name};"

      copy_sql = <<-SQL
          #{permissions_statements};
          COPY #{full_table_name}
          FROM 's3://#{archive_bucket}/#{manifest_file}'
          #{credentials_str}
          MANIFEST EXPLICIT_IDS #{copy_options};
      SQL

      Que.log level: :info, msg: "Starting to create and copy table #{full_table_name}"

      RSPool.with do |conn|
        conn.transaction do
          conn.exec(create_table_sql)
          conn.exec(lock_sql)
          conn.exec(copy_sql)
        end
      end

      Que.log level: :info, msg: "Done copying table #{full_table_name}"
      # delete reference in TableArchive - we are done with this archive record
      tbl = Models::TableArchive.find_by(schema_name: schema_name, table_name: table_name)
      tbl.destroy! unless tbl.nil?

      # delete s3 archive files
      s3_bucket.objects(prefix: archive_prefix).each(&:delete)

      # run TableReport to add the reference to this new table
      Jobs::TableReports.run(job_id, user_id, schema_name: schema_name, table_name: table_name)

      # done return schema+name of newly created table
      {schema: schema_name, table: table_name}
    end

    ##
    # in case of success
    #
    def success(job_run, job_id, user_id, options={})
      subject = "Restore succeeded"
      body = "Succeeded in restoring #{options[:db][:schema]}.#{options[:db][:table]}"
      mail(options[:email], subject, body, options.fetch('mail', {})) unless options[:email].nil?
    end

    ##
    # in case of error
    #
    def error(job_run, job_id, user_id, options={})
      subject = "ERROR: Restore failed"
      body = "Failed to restore #{options[:db][:schema]}.#{options[:db][:table]}
The following error description might be helpful: '#{job_run.error}'"

      mail_options = {
          cc: GlobalConfig.polizei('job_failure_cc'),
          bcc: GlobalConfig.polizei('job_failure_bcc')
      }.merge(options.fetch('mail', {}))
      # if it's a filtered exception we won't notify engineering
      if exception_filtered?(job_run.error, job_run.error_type)
        mail_options[:cc]  = nil
        mail_options[:bcc] = nil
      end
      mail(options[:email], subject, body, mail_options) unless options[:email].nil?
    end

    private

    ##
    # common sending code
    #
    def mail(to, subject, body, options={})
      pony_options = {to: to, subject: subject, body: body}.merge(options)
      Pony.mail(pony_options)
    end
  end
end
