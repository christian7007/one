# -------------------------------------------------------------------------- #
# Copyright 2002-2019, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

ONE_LOCATION = ENV['ONE_LOCATION']

if !ONE_LOCATION
    RUBY_LIB_LOCATION = '/usr/lib/one/ruby'
    GEMS_LOCATION     = '/usr/share/one/gems'
    LOG_LOCATION      = '/var/log/one'
    VAR_LOCATION      = '/var/lib/one'
    ETC_LOCATION      = '/etc/one'
    LIB_LOCATION      = '/usr/lib/one'
else
    RUBY_LIB_LOCATION = ONE_LOCATION + '/lib/ruby'
    GEMS_LOCATION     = ONE_LOCATION + '/share/gems'
    VAR_LOCATION      = ONE_LOCATION + '/var'
    LOG_LOCATION      = ONE_LOCATION + '/var'
    ETC_LOCATION      = ONE_LOCATION + '/etc'
    LIB_LOCATION      = ONE_LOCATION + '/lib'
end

ONEFLOW_AUTH       = VAR_LOCATION + '/.one/oneflow_auth'
ONEFLOW_LOG        = LOG_LOCATION + '/oneflow.log'
CONFIGURATION_FILE = ETC_LOCATION + '/oneflow-server.conf'

if File.directory?(GEMS_LOCATION)
    Gem.use_paths(GEMS_LOCATION)
end

$LOAD_PATH << RUBY_LIB_LOCATION
$LOAD_PATH << RUBY_LIB_LOCATION + '/cloud'
$LOAD_PATH << LIB_LOCATION + '/oneflow/lib'

require 'rubygems'
require 'sinatra'
require 'yaml'

require 'CloudAuth'
require 'CloudServer'

require 'models'
require 'log'

require 'LifeCycleManager'
require 'EventManager'

DEFAULT_VM_NAME_TEMPLATE = '$ROLE_NAME_$VM_NUMBER_(service_$SERVICE_ID)'

##############################################################################
# Configuration
##############################################################################

begin
    conf = YAML.load_file(CONFIGURATION_FILE)
rescue Exception => e
    STDERR.puts "Error parsing config file #{CONFIGURATION_FILE}: #{e.message}"
    exit 1
end

conf[:debug_level]  ||= 2
conf[:lcm_interval] ||= 30
conf[:default_cooldown] ||= 300
conf[:shutdown_action] ||= 'terminate'
conf[:action_number] ||= 1
conf[:action_period] ||= 60

conf[:auth] = 'opennebula'

set :bind, conf[:host]
set :port, conf[:port]

set :config, conf

include CloudLogger

logger = enable_logging ONEFLOW_LOG, conf[:debug_level].to_i

use Rack::Session::Pool, :key => 'oneflow'

Log.logger = logger
Log.level  = conf[:debug_level].to_i

LOG_COMP = 'ONEFLOW'

Log.info LOG_COMP, 'Starting server'

begin
    ENV['ONE_CIPHER_AUTH'] = ONEFLOW_AUTH
    cloud_auth = CloudAuth.new(conf)
rescue => e
    message = "Error initializing authentication system : #{e.message}"
    Log.error LOG_COMP, message
    STDERR.puts message
    exit(-1)
end

set :cloud_auth, cloud_auth

##############################################################################
# Helpers
##############################################################################

before do
    auth = Rack::Auth::Basic::Request.new(request.env)

    if auth.provided? && auth.basic?
        username, password = auth.credentials

        @client = OpenNebula::Client.new("#{username}:#{password}",
                                         conf[:one_xmlrpc])
    else
        error 401, 'A username and password must be provided'
    end
end

##############################################################################
# Defaults
##############################################################################

Role.init_default_cooldown(conf[:default_cooldown])
Role.init_default_shutdown(conf[:shutdown_action])
Role.init_force_deletion(conf[:force_deletion])

conf[:vm_name_template] ||= DEFAULT_VM_NAME_TEMPLATE
Role.init_default_vm_name_template(conf[:vm_name_template])
ServiceTemplate.init_default_vn_name_template(conf[:vn_name_template])

##############################################################################
# LCM and Event Manager
##############################################################################

lcm = ServiceLCM.new(10, cloud_auth)

##############################################################################
# Service
##############################################################################

get '/service' do
    # Read-only object
    service_pool = OpenNebula::ServicePool.new(nil, @client)

    rc = service_pool.info
    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    status 200

    body service_pool.to_json
end

get '/service/:id' do
    service = Service.new_with_id(params[:id], @client)

    rc = service.info
    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    status 200

    body service.to_json
end

delete '/service/:id' do
    # Read-only object
    service = OpenNebula::Service.new_with_id(params[:id], @client)

    rc = service.info

    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
        return status 204 # TODO, check proper return code
    end

    return status 204 if service.state == Service::STATE['DELETING']

    # Starts service undeploying async
    lcm.am.trigger_action(:undeploy, service.id, service.id)

    status 204
end

post '/service/:id/action' do
    action = JSON.parse(request.body.read)['action']
    opts   = action['params']

    case action['perform']
    when 'shutdown'
        service.shutdown
    when 'recover'
        lcm.am.trigger_action(:recover, params[:id], params[:id])
    when 'deploy'
        service.recover
    when 'chown'
        if opts && opts['owner_id']
            u_id = opts['owner_id'].to_i
            g_id = (opts['group_id'] || -1).to_i

            lcm.chown_action(@client, params[:id], u_id, g_id)
        else
            OpenNebula::Error.new("Action #{action['perform']}: " \
                    'You have to specify a UID')
        end
    when 'chgrp'
        if opts && opts['group_id']
            g_id = opts['group_id'].to_i

            lcm.chown_action(@client, params[:id], -1, g_id)
        else
            OpenNebula::Error.new("Action #{action['perform']}: " \
                    'You have to specify a GID')
        end
    when 'chmod'
        if opts && opts['octet']
            lcm.chmod_action(@client, params[:id], opts['octet'])
        else
            OpenNebula::Error.new("Action #{action['perform']}: " \
                    'You have to specify an OCTET')
        end
    when 'rename'
        if opts && opts['name']
            lcm.rename_action(@client, params[:id], opts['name'])
        else
            OpenNebula::Error.new("Action #{action['perform']}: " \
                    'You have to specify a name')
        end
    when 'update'
        if opts && opts['append']
            if opts['template_json']
                begin
                    rc = service.update(opts['template_json'], true)
                    status 204
                rescue Validator::ParseException, JSON::ParserError
                    OpenNebula::Error.new($!.message)
                end
            elsif opts['template_raw']
                rc = service.update_raw(opts['template_raw'], true)
                status 204
            else
                OpenNebula::Error.new("Action #{action['perform']}: " \
                        'You have to provide a template')
            end
        else
            OpenNebula::Error.new("Action #{action['perform']}: " \
                    'Only supported for append')
        end
    else
        OpenNebula::Error.new("Action #{action['perform']} not supported")
    end

    status 204
end

put '/service/:id/role/:name' do
    service_pool = nil # OpenNebula::ServicePool.new(@client)

    rc = nil
    service_rc = service_pool.get(params[:id]) do |service|
        begin
            rc = service.update_role(params[:name], request.body.read)
        rescue Validator::ParseException, JSON::ParserError
            return error 400, $!.message
        end
    end

    if OpenNebula.is_error?(service_rc)
        error CloudServer::HTTP_ERROR_CODE[service_rc.errno], service_rc.message
    end

    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    status 204
end

post '/service/:id/role/:role_name/action' do
    action = JSON.parse(request.body.read)['action']
    opts   = action['params']

    # Use defaults only if one of the options is supplied
    if opts['period'].nil? && opts['number'].nil?
        opts['period'] = conf[:action_period] if opts['period'].nil?
        opts['number'] = conf[:action_number] if opts['number'].nil?
    end

    lcm.sched_action(@client,
                     params[:id],
                     params[:role_name],
                     action['perform'],
                     opts['period'],
                     opts['number'])

    status 201
end

post '/service/:id/scale' do
    call_body = JSON.parse(request.body.read)

    service_id  = params[:id]
    role_name   = call_body['role_name']
    cardinality = call_body['cardinality'].to_i
    force       = call_body['force']

    # TODO, check valid state and service exist
    lcm.am.trigger_action(:scale,
                          service_id,
                          service_id,
                          role_name,
                          cardinality,
                          force)

    status 201
    body
end

##############################################################################
# Service Template
##############################################################################

get '/service_template' do
    s_template_pool = OpenNebula::ServiceTemplatePool.new(@client, OpenNebula::Pool::INFO_ALL)

    rc = s_template_pool.info
    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    status 200

    body s_template_pool.to_json
end

get '/service_template/:id' do
    service_template = OpenNebula::ServiceTemplate.new_with_id(params[:id], @client)

    rc = service_template.info
    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    status 200

    body service_template.to_json
end

delete '/service_template/:id' do
    service_template = OpenNebula::ServiceTemplate.new_with_id(params[:id], @client)

    rc = service_template.delete
    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    status 204
end

put '/service_template/:id' do
    service_template = OpenNebula::ServiceTemplate.new_with_id(params[:id], @client)

    begin
        rc = service_template.update(request.body.read)
    rescue Validator::ParseException, JSON::ParserError
        error 400, $!.message
    end

    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    service_template.info

    status 200
    body service_template.to_json
end

post '/service_template' do
    s_template = OpenNebula::ServiceTemplate.new(
                    OpenNebula::ServiceTemplate.build_xml,
                    @client)

    begin
        rc = s_template.allocate(request.body.read)
    rescue Validator::ParseException, JSON::ParserError
        error 400, $!.message
    end

    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end

    s_template.info

    status 201
    # body Parser.render(rc)
    body s_template.to_json
end

post '/service_template/:id/action' do
    service_template = OpenNebula::ServiceTemplate.new_with_id(params[:id], @client)

    action = JSON.parse(request.body.read)['action']

    opts   = action['params']
    opts   = {} if opts.nil?

    # rubocop:disable Style/ConditionalAssignment
    # rubocop:disable Layout/CaseIndentation
    # rubocop:disable Layout/EndAlignment
    rc = case action['perform']
    when 'instantiate'
        rc = service_template.info

        if OpenNebula.is_error?(rc)
            error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
        end

        merge_template = opts['merge_template']
        service_json = JSON.parse(service_template.to_json)

        # Check custom_attrs
        if !(service_json['DOCUMENT']['TEMPLATE']['BODY']['custom_attrs'].keys -
           merge_template['custom_attrs_values'].keys).empty?
            status 204
            return body 'Every custom_attrs key must have its value defined '\
                        'at custom_attrs_value'
        end

        # Check networks
        if !(service_json['DOCUMENT']['TEMPLATE']['BODY']['networks'].keys -
           merge_template['networks_values'].collect {|i| i.keys }.flatten)
           .empty?
            status 204
            return body 'Every network key must have its value defined at ' \
                        'networks_value'
        end

        # Creates service document
        service = service_template.instantiate(merge_template)

        if OpenNebula.is_error?(service)
            error CloudServer::HTTP_ERROR_CODE[service.errno], service.message
        else
            # Starts service deployment async
            lcm.am.trigger_action(:deploy, service.id, service.id)

            service_json = service.nil? ? '' : service.to_json

            status 201
            body service_json
        end
    when 'chown'
        if opts && opts['owner_id']
            args = []
            args << opts['owner_id'].to_i
            args << (opts['group_id'].to_i || -1)

            status 204
            service_template.chown(*args)
        else
            OpenNebula::Error.new("Action #{action['perform']}: "\
                                  'You have to specify a UID')
        end
    when 'chgrp'
        if opts && opts['group_id']
            status 204
            service_template.chown(-1, opts['group_id'].to_i)
        else
            OpenNebula::Error.new("Action #{action['perform']}: "\
                    'You have to specify a GID')
        end
    when 'chmod'
        if opts && opts['octet']
            status 204
            service_template.chmod_octet(opts['octet'])
        else
            OpenNebula::Error.new("Action #{action['perform']}: "\
                                  'You have to specify an OCTET')
        end
    when 'update'
        if opts && opts['template_json']
            begin
                rc = service_template.update(
                    opts['template_json'],
                    (opts['append'] == true))

                status 204
            rescue Validator::ParseException, JSON::ParserError
                OpenNebula::Error.new($!.message)
            end
        elsif opts && opts['template_raw']
            rc = service_template.update_raw(
                opts['template_raw'],
                (opts['append'] == true))

            status 204
        else
            OpenNebula::Error.new("Action #{action['perform']}: "\
                                  'You have to provide a template')
        end
    when 'rename'
        status 204
        service_template.rename(opts['name'])
    when 'clone'
        rc = service_template.clone(opts['name'])
        if OpenNebula.is_error?(rc)
            error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
        end

        new_stemplate = OpenNebula::ServiceTemplate.new_with_id(rc, @client)
        new_stemplate.info
        if OpenNebula.is_error?(new_stemplate)
            error CloudServer::HTTP_ERROR_CODE[new_stemplate.errno], new_stemplate.message
        end

        status 201
        body new_stemplate.to_json
    else
        OpenNebula::Error.new("Action #{action['perform']} not supported")
    end
    # rubocop:enable Style/ConditionalAssignment
    # rubocop:enable Layout/CaseIndentation
    # rubocop:enable Layout/EndAlignment

    if OpenNebula.is_error?(rc)
        error CloudServer::HTTP_ERROR_CODE[rc.errno], rc.message
    end
end
