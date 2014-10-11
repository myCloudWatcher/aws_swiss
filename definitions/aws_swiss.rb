define :aws_swiss, \
  :aws_access_key_id => nil, \
  :aws_secret_access_key => nil, \
  :cidr => nil, \
  :port => nil, \
  :rds_name => nil, \
  :enable => true \
do

  security_group = params[:name]
  rds_name = params[:rds_name]
  cidr = params[:cidr]
  port = params[:port]
  
  raise "Illegal use of aws_swiss definition: only one of 'port' and 'rds_name' must be specified" if rds_name.nil? == port.nil?
  
  if !port.nil?
    port = port.to_s
  end
  
  is_group_name = security_group[/sg-([0-9a-f]{8})/, 1].nil?
  if is_group_name
    group_arg_name = "group-name"
  else
    group_arg_name = "group-id"
  end
  
  aws_instance_metadata_url = "http://169.254.169.254/latest/meta-data"
  region=%x"curl --silent #{aws_instance_metadata_url}/placement/availability-zone/"[0..-2]
  cidr=%x"curl --silent #{aws_instance_metadata_url}/public-ipv4"+'/32' if cidr.nil? || cidr.size==0
  
  command_base = ""
  if !params[:aws_access_key_id].nil? && !params[:aws_secret_access_key].nil?
    command_base = "AWS_ACCESS_KEY_ID=#{params[:aws_access_key_id]} AWS_SECRET_ACCESS_KEY=#{params[:aws_secret_access_key]} "
  end
  command_base << "/usr/local/bin/aws --region #{region} "

  target_name = "CIDR #{cidr}" + (port.nil? ? "" : " port #{port}") + " to " +
    (port.nil? ? "rds instance #{rds_name} " : "") +  "security group #{security_group}"

  include_recipe "awscli"
  require 'json'
  
  if params[:enable] # authorize
    if port.nil? # RDS security group
      ruby_block "authorize RDS ingress for #{target_name}" do
        block do
          system(command_base + "rds authorize-db-security-group-ingress --db-security-group-name #{security_group} --cidrip #{cidr}")
        end
        only_if do
          str=%x^#{command_base} rds describe-db-security-groups --db-security-group-name #{security_group}^
          json=JSON.parse(str)
          json['DBSecurityGroups'].first['IPRanges'].none? { | cidrHash | 
            cidrHash['CIDRIP'] == cidr && ["authorized", "authorizing"].include?(cidrHash['Status'])
          }
        end
      end
    else # EC2 security group
      ruby_block "authorize RDS ingress for #{target_name}" do
        block do
          system(command_base + "ec2 authorize-security-group-ingress --#{group_arg_name} #{security_group} --cidr #{cidr} --protocol tcp --port #{port}")
        end
        only_if do
          str=%x^#{command_base} ec2 describe-security-groups --#{group_arg_name}s #{security_group}^
          json=JSON.parse(str)
          json['SecurityGroups'].first['IpPermissions'].none? { |hole|
            hole['ToPort']==port && hole['FromPort']==port && hole['IpProtocol']="tcp" && hole['IpRanges'].any? { |cidrMap| cidrMap['CidrIp']==cidr}
          }
        end
      end
    end
  else # revoke
    if port.nil? # RDS security group
      ruby_block "revoke RDS ingress for #{target_name}" do
        block do
          system(command_base + "rds revoke-db-security-group-ingress --db-security-group-name #{security_group} --cidrip #{cidr}")
        end
        only_if do
          str=%x^#{command_base} rds describe-db-security-groups --db-security-group-name #{security_group}^
          json=JSON.parse(str)
          json['DBSecurityGroups'].first['IPRanges'].any? { | cidrHash | 
            cidrHash['CIDRIP'] == cidr && ["authorized", "authorizing"].include?(cidrHash['Status'])
          }
        end
      end
    else # EC2 security group
      ruby_block "revoke EC2 ingress for #{target_name}" do
        block do
          system(command_base + "ec2 revoke-security-group-ingress --#{group_arg_name} #{security_group} --cidr #{cidr} --protocol tcp --port #{port}")
        end
        # non-existent ingress can be revoked without any error, so no only_if guard here
      end
    end
  end

end
