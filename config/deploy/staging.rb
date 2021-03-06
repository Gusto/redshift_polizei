require './lib/global_config'
GlobalConfig.load_config_file('deploy', 'config/polizei.yml')
SERVER_STAGING_URL  = GlobalConfig.deploy('deploy_server_staging_url')
fail ArgumentError, "You need to set 'deploy_server_staging_url' in config/polizei.yml" if SERVER_STAGING_URL.blank?

server SERVER_STAGING_URL, :roles => %w{app web db cron}
set :rack_env, 'staging'
set :default_branch, 'master'
invoke 'git:ask_branch'
