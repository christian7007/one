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

require 'strategy'
require 'ActionManager'

# Service Life Cycle Manager
class ServiceLCM

    attr_writer :event_manager
    attr_reader :am

    LOG_COMP = 'LCM'

    ACTIONS = {
        # Actions
        'DEPLOY'   => :deploy,
        'UNDEPLOY' => :undeploy,
        'SCALE'    => :scale,
        'RECOVER'  => :recover,
        'CHOWN'    => :chown,
        'CHMOD'    => :chmod,
        'RENAME'   => :rename,
        'SCHED'    => :sched,

        # Callbacks
        'DEPLOY_CB'            => :deploy_cb,
        'DEPLOY_FAILURE_CB'    => :deploy_failure_cb,
        'UNDEPLOY_CB'          => :undeploy_cb,
        'UNDEPLOY_FAILURE_CB'  => :undeploy_failure_cb,
        'COOLDOWN_CB'          => :cooldown_cb,
        'SCALEUP_CB'           => :scaleup_cb,
        'SCALEUP_FAILURE_CB'   => :scaleup_failure_cb,
        'SCALEDOWN_CB'         => :scaledown_cb,
        'SCALEDOWN_FAILURE_CB' => :scaledown_failure_cb
    }

    def initialize(concurrency, cloud_auth)
        @cloud_auth = cloud_auth
        @event_manager = nil
        @am = ActionManager.new(concurrency, true)
        @srv_pool = ServicePool.new(@cloud_auth, nil)

        # Register Action Manager actions
        @am.register_action(ACTIONS['DEPLOY'], method('deploy_action'))
        @am.register_action(ACTIONS['DEPLOY_CB'], method('deploy_cb'))
        @am.register_action(ACTIONS['DEPLOY_FAILURE_CB'], method('deploy_failure_cb'))
        @am.register_action(ACTIONS['UNDEPLOY'], method('undeploy_action'))
        @am.register_action(ACTIONS['UNDEPLOY_CB'], method('undeploy_cb'))
        @am.register_action(ACTIONS['UNDEPLOY_FAILURE_CB'], method('undeploy_failure_cb'))
        @am.register_action(ACTIONS['SCALE'], method('scale_action'))
        @am.register_action(ACTIONS['SCALEUP_CB'], method('scaleup_cb'))
        @am.register_action(ACTIONS['SCALEUP_FAILURE_CB'], method('scaleup_failure_cb'))
        @am.register_action(ACTIONS['SCALEDOWN_CB'], method('scaledown_cb'))
        @am.register_action(ACTIONS['SCALEDOWN_FAILURE_CB'], method('scaledown_failure_cb'))
        @am.register_action(ACTIONS['COOLDOWN_CB'], method('cooldown_cb'))
        @am.register_action(ACTIONS['RECOVER'], method('recover_action'))
        @am.register_action(ACTIONS['CHOWN'], method('chown_action'))
        @am.register_action(ACTIONS['CHMOD'], method('chmod_action'))
        @am.register_action(ACTIONS['RENAME'], method('rename_action'))
        @am.register_action(ACTIONS['SCHED'], method('sched_action'))

        Thread.new { @am.start_listener }
    end

    private

    ############################################################################
    # Actions
    ############################################################################
    def deploy_action(service_id)
        rc = @srv_pool.get(service_id) do |service|
            # Create vnets only first time action is called
            if service.state == Service::STATE['PENDING']
                rc = service.deploy_networks

                if OpenNebula.is_error?(rc)
                    Log.error LOG_COMP, rc.message
                    service.set_state(Service::STATE['FAILED_DEPLOYING'])
                    service.update

                    break
                end
            end

            set_deploy_strategy(service)

            roles = service.roles_deploy

            # Maybe roles.empty? because are being deploying in other threads
            if roles.empty?
                if service.all_roles_running?
                    service.set_state(Service::STATE['RUNNING'])
                    service.update
                end
                # If there is no node in PENDING the service is not modified.
                break
            end

            rc = deploy_roles(roles, 'DEPLOYING', 'FAILED_DEPLOYING', false)

            if rc
                service.set_state(Service::STATE['DEPLOYING'])
            else
                service.set_state(Service::STATE['FAILED_DEPLOYING'])
            end

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def undeploy_action(service_id)
        rc = @srv_pool.get(service_id) do |service|
            set_deploy_strategy(service)

            if service.transient_state? &&
               service.state != Service::STATE['UNDEPLOYING']
                Log.error LOG_COMP, 'Service cannot be undeployed in '\
                                    "state: #{service.state_str}"

                break
            end

            roles = service.roles_shutdown

            if roles.empty?
                if service.all_roles_done?
                    service.set_state(Service::STATE['DONE'])
                    service.update
                end
                # If there is no node which needs to be shutdown the service is not modified.
                break
            end

            rc = undeploy_roles(roles,
                                'UNDEPLOYING',
                                'FAILED_UNDEPLOYING',
                                false)

            if rc
                service.set_state(Service::STATE['UNDEPLOYING'])
            else
                service.set_state(Service::STATE['FAILED_UNDEPLOYING'])
            end

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def scale_action(service_id, role_name, cardinality, force)
        rc = @srv_pool.get(service_id) do |service|
            if !service.can_scale?
                Log.error LOG_COMP, 'Failure scaling service. ' \
                                    'Services cannot be scaled in ' \
                                    "#{service.state_str} state."

                break
            end

            rc = nil
            # TODO, validate role_name
            role = service.roles[role_name]

            cardinality_diff = cardinality - role.cardinality

            set_cardinality(role, cardinality, force)

            if cardinality_diff > 0
                rc = deploy_roles({ role_name => role },
                                  'SCALING',
                                  'FAILED_SCALING',
                                  true)
            elsif cardinality_diff < 0
                rc = undeploy_roles({ role_name => role },
                                    'SCALING',
                                    'FAILED_SCALING',
                                    true)
            end

            if rc
                service.set_state(Service::STATE['SCALING'])
            else
                service.set_state(Service::STATE['FAILED_SCALING'])
            end

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def recover_action(service_id)
        state = ''

        # TODO, kill other proceses? (other recovers)
        rc = @srv_pool.get(service_id) do |service|
            state = service.state

            case state
            when Service::STATE['FAILED_DEPLOYING']
                recover_deploy(service)
            when Service::STATE['FAILED_UNDEPLOYING']
                recover_undeploy(service)
            when Service::STATE['FAILED_SCALING']
                recover_scale(service)
            else
                OpenNebula::Error.new('Recover action is not ' \
                            "available for state #{service.state_str}")
            end
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def chown_action(service_id, u_id, g_id)
        rc = @srv_pool.get(service_id) do |service|
            rc = service.chown(u_id, g_id)

            if OpenNebula.is_error?(rc)
                rc
            end
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def chmod_action(service_id, octet)
        rc = @srv_pool.get(service_id) do |service|
            rc = service.chmod_octet(octet)

            if OpenNebula.is_error?(rc)
                rc
            end
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def rename_action(service_id, new_name)
        rc = @srv_pool.get(service_id) do |service|
            rc = service.rename(new_name)

            if OpenNebula.is_error?(rc)
                rc
            end
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def sched_action(service_id, role_name, action, period, number)
        rc = @srv_pool.get(service_id) do |service|
            roles = service.roles

            role = roles[role_name]

            if role.nil?
                break OpenNebula::Error.new("Role '#{role_name}' "\
                                            'not found')
            else
                role.batch_action(action, period, number)
            end
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    ############################################################################
    # Callbacks
    ############################################################################

    def deploy_cb(service_id, role_name)
        rc = @srv_pool.get(service_id) do |service|
            service.roles[role_name].set_state(Role::STATE['RUNNING'])

            if service.all_roles_running?
                service.set_state(Service::STATE['RUNNING'])
            elsif service.strategy == 'straight'
                @am.trigger_action(:deploy, service.id, service_id)
            end

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def deploy_failure_cb(service_id, role_name)
        rc = @srv_pool.get(service_id) do |service|
            # stop actions for the service if deploy fails
            @event_manager.cancel_action(service_id)

            service.set_state(Service::STATE['FAILED_DEPLOYING'])
            service.roles[role_name].set_state(Role::STATE['FAILED_DEPLOYING'])

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def undeploy_cb(service_id, role_name, nodes)
        rc = @srv_pool.get(service_id) do |service|
            service.roles[role_name].set_state(Role::STATE['DONE'])

            service.roles[role_name].nodes.delete_if do |node|
                !nodes[:failure].include?(node['deploy_id']) &&
                    nodes[:successful].include?(node['deploy_id'])
            end

            if service.all_roles_done?
                rc = service.delete_networks

                if !rc.empty?
                    Log.info LOG_COMP, 'Error trying to delete '\
                                      "Virtual Networks #{rc}"
                end

                service.set_state(Service::STATE['DONE'])
            elsif service.strategy == 'straight'
                @am.trigger_action(:undeploy, service.id, service_id)
            end

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def undeploy_failure_cb(service_id, role_name, nodes)
        rc = @srv_pool.get(service_id) do |service|
            # stop actions for the service if deploy fails
            @event_manager.cancel_action(service_id)

            service.set_state(Service::STATE['FAILED_UNDEPLOYING'])
            service.roles[role_name].set_state(Role::STATE['FAILED_UNDEPLOYING'])

            service.roles[role_name].nodes.delete_if do |node|
                !nodes[:failure].include?(node['deploy_id']) &&
                    nodes[:successful].include?(node['deploy_id'])
            end

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def scaleup_cb(service_id, role_name)
        rc = @srv_pool.get(service_id) do |service|
            service.set_state(Service::STATE['COOLDOWN'])
            service.roles[role_name].set_state(Role::STATE['COOLDOWN'])
            @event_manager.trigger_action(:wait_cooldown,
                                          service.id,
                                          service.id,
                                          role_name,
                                          10) # TODO, config time

            service.roles[role_name].clean_scale_way
            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def scaledown_cb(service_id, role_name, nodes)
        rc = @srv_pool.get(service_id) do |service|
            service.set_state(Service::STATE['COOLDOWN'])
            service.roles[role_name].set_state(Role::STATE['COOLDOWN'])

            service.roles[role_name].nodes.delete_if do |node|
                !nodes[:failure].include?(node['deploy_id']) &&
                    nodes[:successful].include?(node['deploy_id'])
            end

            @event_manager.trigger_action(:wait_cooldown,
                                          service.id,
                                          service.id,
                                          role_name,
                                          10) # TODO, config time

            service.roles[role_name].clean_scale_way

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def scaleup_failure_cb(service_id, role_name)
        rc = @srv_pool.get(service_id) do |service|
            # stop actions for the service if deploy fails
            @event_manager.cancel_action(service_id)

            service.set_state(Service::STATE['FAILED_SCALING'])
            service.roles[role_name].set_state(Role::STATE['FAILED_SCALING'])

            service.roles[role_name].scale_way('UP')

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def scaledown_failure_cb(service_id, role_name, nodes)
        rc = @srv_pool.get(service_id) do |service|
            # stop actions for the service if deploy fails
            @event_manager.cancel_action(service_id)

            role = service.roles[role_name]

            service.set_state(Service::STATE['FAILED_SCALING'])
            role.set_state(Role::STATE['FAILED_SCALING'])

            role.nodes.delete_if do |node|
                !nodes[:failure].include?(node['deploy_id']) &&
                    nodes[:successful].include?(node['deploy_id'])
            end

            role.scale_way('DOWN')

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    def cooldown_cb(service_id, role_name)
        rc = @srv_pool.get(service_id) do |service|
            service.set_state(Service::STATE['RUNNING'])
            service.roles[role_name].set_state(Role::STATE['RUNNING'])

            service.update
        end

        Log.error LOG_COMP, rc.message if OpenNebula.is_error?(rc)
    end

    ############################################################################
    # Helpers
    ############################################################################

    # Returns the deployment strategy for the given Service
    # @param [Service] service the service
    # rubocop:disable Naming/AccessorMethodName
    def set_deploy_strategy(service)
        # rubocop:enable Naming/AccessorMethodName
        case service.strategy
        when 'straight'
            service.extend(Straight)
        else
            service.extend(Strategy)
        end
    end

    # Returns true if the deployments of all roles was fine and
    # update their state consequently
    # @param [Array<Role>] roles to be deployed
    # @param [Role::STATE] success_state new state of the role
    #                      if deployed successfuly
    # @param [Role::STATE] error_state new state of the role
    #                      if deployed unsuccessfuly
    def deploy_roles(roles, success_state, error_state, scale)
        action = nil

        if scale
            action = :wait_scaleup
        else
            action = :wait_deploy
        end

        roles.each do |_name, role|
            rc = role.deploy

            if !rc[0]
                role.set_state(Role::STATE[error_state])
                Log.error LOG_COMP, rc[1]
                return false
            end

            role.set_state(Role::STATE[success_state])

            @event_manager.trigger_action(action,
                                          role.service.id,
                                          role.service.id,
                                          role.name,
                                          rc[0])
        end

        true
    end

    def undeploy_roles(roles, success_state, error_state, scale)
        action = nil

        if scale
            action = :wait_scaledown
        else
            action = :wait_undeploy
        end

        roles.each do |_name, role|
            rc = role.shutdown

            if !rc[0]
                role.set_state(Role::STATE[error_state])
                break
            end

            role.set_state(Role::STATE[success_state])

            # TODO, take only subset of nodes which needs to be undeployed (new role.nodes_undeployed_ids ?)
            @event_manager.trigger_action(action,
                                          role.service.id,
                                          role.service.id,
                                          role.name,
                                          rc[0])
        end
    end

    def set_cardinality(role, cardinality, force)
        tmpl_json = "{ \"cardinality\" : #{cardinality},\n" \
                    "  \"force\" : #{force} }"

        rc = role.update(JSON.parse(tmpl_json))

        return rc if OpenNebula.is_error?(rc)

        nil
    end

    def recover_deploy(service)
        service.roles.each do |name, role|
            next if role.state != Role::STATE['FAILED_DEPLOYING']

            nodes = role.recover_deploy

            next if nodes.empty?

            @event_manager.trigger_action(:wait_deploy,
                                          service.id,
                                          service.id,
                                          name,
                                          nodes)
        end
    end

    def recover_undeploy(service)
        service.roles.each do |name, role|
            next if role.state != Role::STATE['FAILED_UNDEPLOYING']

            nodes = role.recover_undeploy

            next if nodes.empty?

            @event_manager.trigger_action(:wait_undeploy,
                                          service.id,
                                          service.id,
                                          name,
                                          nodes)
        end
    end

    def recover_scale(service)
        service.roles.each do |name, role|
            next if role.state != Role::STATE['FAILED_SCALING']

            nodes, up = role.recover_scale

            next if nodes.empty?

            if up
                action = :wait_scaleup
            else
                action = :wait_scaledown
            end

            @event_manager.trigger_action(action,
                                          service.id,
                                          service.id,
                                          name,
                                          nodes)
        end
    end

end
