require_relative '../../main'

module Jobs
  ##
  # job archiving Redshift table into S3
  #
  # Please see `BaseJob` class documentation on how to run
  # any job using its general interface.
  #
  class ArchiveJob < Desmond::BaseJob
    ##
    # runs an archive
    # see `BaseJob` for information on arguments except +options+.
    #
    # the following +options+ are required:
    # - db
    #   - connection_id: ActiveRecord connection id used to connect to database
    #   - username: database username
    #   - password: database password
    #   - schema: schema of table to archive
    #   - table: name of table to archive
    # - s3
    #   - access_key_id: s3 access key
    #   - secret_access_key: s3 secret key
    #   - archive_bucket: bucket to place unloaded data into
    #   - archive_prefix: prefix to append to s3 data stored
    #
    # the following +options+ are additionally supported:
    # - db
    #   - timeout: connection timeout to database
    # - unload_options: options for the Redshift UNLOAD command
    #   - allowoverwrite: if true, will use the ALLOWOVERWRITE unload option
    #   - gzip: if true, will use the GZIP unload option
    #   - addquotes: if true, will use the REMOVEQUOTES unload option
    #   - escape: if true, will use the ESCAPE unload option
    #   - null_as: string to use for the NULL AS unload option
    #
    def execute(job_id, user_id, options={})
      fail 'No database options!' if options[:db].nil?
      fail 'No s3 options!' if options[:s3].nil?

      # S3 location to store unloaded data
      archive_bucket = options[:s3][:archive_bucket]
      fail 'Empty bucket name!' if archive_bucket.nil? || archive_bucket.empty?
      archive_prefix = options[:s3][:archive_prefix]
      fail 'Empty prefix name!' if archive_prefix.nil? || archive_prefix.empty?

      # s3 credentials for the bucket to unload to
      access_key = options[:s3][:access_key_id]
      fail 'Empty access key!' if access_key.nil? || access_key.empty?
      secret_key = options[:s3][:secret_access_key]
      fail 'Empty secret key!' if secret_key.nil? || secret_key.empty?

      # construct full escaped table name
      schema_name = options[:db][:schema]
      fail 'Empty schema name!' if schema_name.nil? || schema_name.empty?
      table_name = options[:db][:table]
      fail 'Empty table name!' if table_name.nil? || table_name.empty?

      # get the latest info on the table for the later TableArchive creation
      Jobs::TableReports.run(1, user_id, schema_name: schema_name, table_name: table_name)
      tbl = Models::TableReport.find_by(schema_name: schema_name, table_name: table_name)
      table_info = {}
      unless tbl.nil?
        table_info[:size_in_mb] = tbl.size_in_mb
        table_info[:dist_key] = tbl.dist_key
        table_info[:dist_style] = tbl.dist_style
        table_info[:sort_keys] = tbl.sort_keys
        table_info[:has_col_encodings] = tbl.has_col_encodings
      end

      # check if archive already exists
      fail 'Archive entry already exists for this table!' unless Models::TableArchive.find_by(schema_name: schema_name,
                                                                                              table_name: table_name).nil?

      # run a TableStructureExportJob
      ddl_s3_key = "#{archive_prefix}ddl"
      Jobs::TableStructureExportJob.run(1, user_id, {
                                             schema_name: schema_name,
                                             table_name: table_name,
                                             s3_bucket: archive_bucket,
                                             s3_key: ddl_s3_key,
                                             mail: {nomailer: true}
                                         })
      ddl_obj = AWS::S3.new.buckets[archive_bucket].objects[ddl_s3_key]
      fail 'Failed to export DDL!' unless ddl_obj.exists?
      # ensure TableStructureExportJob outputted a single CREATE TABLE statement
      ddl_match = ddl_obj.read.scan(/CREATE TABLE/mi)
      fail 'Table has foreign constraints!' if ddl_match.length != 1

      # execute UNLOAD + DROP
      archive_bucket = Desmond::PGUtil.escape_string(archive_bucket)
      archive_prefix = Desmond::PGUtil.escape_string(archive_prefix)
      access_key = Desmond::PGUtil.escape_string(access_key)
      secret_key = Desmond::PGUtil.escape_string(secret_key)
      full_table_name = Desmond::PGUtil.get_escaped_table_name(options[:db], schema_name, table_name)
      unload_options = ''
      unless options[:unload_options].nil? || options[:unload_options].empty?
        unload_options += 'ALLOWOVERWRITE' if options[:unload_options][:allowoverwrite]
        unload_options += ' GZIP' if options[:unload_options][:gzip]
        unload_options += ' ADDQUOTES' if options[:unload_options][:addquotes]
        unload_options += ' ESCAPE' if options[:unload_options][:escape]
        unload_options += " NULL AS '#{options[:unload_options][:null_as]}'" unless options[:unload_options][:null_as].nil?
      end
      unload_sql = <<-SQL
          -- Unloads to S3 and truncates #{full_table_name}
          UNLOAD ('SELECT * FROM #{full_table_name}')
          TO 's3://#{archive_bucket}/#{archive_prefix}'
          CREDENTIALS 'aws_access_key_id=#{access_key};aws_secret_access_key=#{secret_key}'
          MANIFEST #{unload_options};
          DROP TABLE #{full_table_name};
      SQL
      conn = Desmond::PGUtil.dedicated_connection(options[:db])
      conn.transaction do
        conn.exec(unload_sql)
      end

      # add new TableArchive database entry
      table_archive = Models::TableArchive.create!(schema_name: schema_name, table_name: table_name,
                                                   archive_bucket: archive_bucket,
                                                   archive_prefix: archive_prefix)
      table_archive.update!(table_info) unless table_info.empty?
      table_archive.save

      # run TableReport to remove the reference to this dropped table
      Jobs::TableReports.run(1, user_id, schema_name: schema_name, table_name: table_name)

      # done return the full path to the s3 manifest and DDL files
      {ddl_file: "s3://#{archive_bucket}/#{ddl_s3_key}", manifest_file: "s3://#{archive_bucket}/#{archive_prefix}manifest"}
    ensure
      conn.close unless conn.nil?
    end

    ##
    # in case of success
    #
    def success(job_run, job_id, user_id, options={})
      subject = "Archive succeeded"
      body = "Succeeded in archiving #{options[:db][:schema]}.#{options[:db][:table]}"
      mail(options[:email], subject, body, options.fetch('mail', {}))
    end

    ##
    # in case of error
    #
    def error(job_run, job_id, user_id, options={})
      subject = "ERROR: Archive failed"
      body = "Failed to archive #{options[:db][:schema]}.#{options[:db][:table]}
The following error description might be helpful: '#{job_run.error}'"

      mail_options = {
          cc: GlobalConfig.polizei('job_failure_cc'),
          bcc: GlobalConfig.polizei('job_failure_bcc')
      }.merge(options.fetch('mail', {}))
      mail(options[:email], subject, body, mail_options)
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
