require 'uri'

module OmniAuth
  module Slack
  
    # Build an access token from access-token-hash or from token-string.
    def self.build_access_token(client_id, client_key, token_string_or_hash)
      client = ::OAuth2::Client.new(
        client_id,
        client_key,
        OmniAuth::Strategies::Slack.default_options['client_options'].map{|k,v| [k.to_sym, v]}.to_h
      )
      
      client.extend Helpers::Client
      client.options[:raise_errors] = false
      
      access_token = case
        when token_string_or_hash.is_a?(String)
          ::OAuth2::AccessToken.new(client, token_string_or_hash)
        when token_string_or_hash.is_a?(Hash)
          ::OAuth2::AccessToken.from_hash(client, token_string_or_hash)
      end
      
      access_token.extend Helpers::AccessToken if access_token
      access_token
    end
    
        
    module Helpers
      module Client
      
        def self.extended(other)
          other.instance_eval do
            singleton_class.send :attr_accessor, :logger, :history, :subdomain
            
            #options[:raise_errors] = false
            
            self.logger = OmniAuth.logger
            self.history = {}
          end
        end
            
        def request(*args)
          logger.debug "(slack) API request #{args[0..1]}"  #; by Client #{self}; in thread #{Thread.current.object_id}.")
          request_output = super(*args)
          uri = args[1].to_s.gsub(/^.*\/([^\/]+)/, '\1') # use single-quote or double-back-slash for replacement.
          history[uri.to_s] = request_output
          #logger.send(:debug, "(slack) API response (#{args[0..1]}) #{request_output.parsed}")
          request_output
        end
        
        def subomain=(sd)
          if !sd.to_s.empty?
            site_uri = URI.parse site
            site_uri.host = "#{sd}.slack.com"
            self.site = site_uri.to_s
            logger.debug "Oauth site uri with custom team_domain #{site_uri}"
            site
          end
        end
        
      end # Client    
    
    
      module AccessToken
      
        def self.extended(other)
          other.instance_eval do
            @main_semaphore = Mutex.new
            @semaphores = {}
          end
        end
        
        # Get a mutex specific to the calling method.
        # This operation is synchronized with its own mutex.
        def semaphore(method_name = caller[0][/`([^']*)'/, 1])
          @main_semaphore.synchronize {
            @semaphores[method_name] ||= Mutex.new
          }
        end

        %w(user_name user_email team_id team_name team_domain).each do |word|
          obj, atrb = word.split('_')
          define_method(word) do
            params[word] ||
            params[obj].to_h[atrb]
          end
        end

        def user_id
          params['user_id'] ||
          params['authorizing_user'].to_h['user_id'] ||
          params['user'].to_h['id']
        end
        
        def uid
          "#{user_id}-#{team_id}"
        end
      
        # Is this a workspace app token?
        def is_app_token?
          case
            when params['token_type'] == 'app' || token.to_s[/^xoxa/]
              true
            when token.to_s[/^xoxp/]
              false
            else
              nil
          end
        end
      
        def apps_permissions_users_list(user=nil)
          return {} unless is_app_token?
          semaphore.synchronize {
            @apps_permissions_users_list ||= (
              r = get('/api/apps.permissions.users.list').parsed
              r['resources'].to_a.inject({}){|h,i| h[i['id']] = i; h} || {}
            )
            user ? @apps_permissions_users_list[user].to_h['scopes'] : @apps_permissions_users_list
          }
        end
        
        def apps_permissions_scopes_list
          return {} unless is_app_token?
            semaphore.synchronize {
            @apps_permissions_scopes_list ||= (
              r = get('/api/apps.permissions.scopes.list').parsed
              r['scopes'] || {}
            )
          }
        end
                
        # Get all scopes, including apps.permissions.users.list if user_id.
        # This now puts all compiled scopes back into params['scopes']
        def all_scopes(user=nil)
          if user && !@all_scopes.to_h.has_key?('identity') || @all_scopes.nil?
            @all_scopes = (
              scopes = case
                when params['scope']
                  {'classic' => params['scope'].split(/[, ]/)}
                when params['scopes']
                  params['scopes']
                else
                  apps_permissions_scopes_list
              end
              
              scopes['identity'] = apps_permissions_users_list(user) if user
              params['scopes'] = scopes
            )
          else
            @all_scopes
          end
        end
      
        # Determine if given scopes exist in current authorization.
        # scopes_hash is hash where:
        #   key == scope type <identity|app_home|team|channel|group|mpim|im>
        #   val == array or string of individual scopes.
        #
        def has_scope?(scope_query, **opts)          
          user = opts[:user_id] || user_id
          base_scopes = case
            when opts[:base_scopes]
              opts[:base_scopes]
            when user && scope_query.is_a?(Hash) && scope_query.keys.detect{|k| k.to_s == 'identity'}
              all_scopes(user)
            else
              all_scopes
          end
          
          logic = case
            when opts[:logic].to_s.downcase == 'or'; :'any?'
            when opts[:logic].to_s.downcase == 'and'; :'all?'
            else :'any?'
          end

          scope_query.send(logic) do |section, scopes|
            test_scopes = case
              when scopes.is_a?(String); scopes.split(/[, ]/)
              when scopes.is_a?(Array); scopes
              else raise "Scope must be a string or array"
            end
            #puts "TESTING with base_scopes: #{base_scopes.to_yaml}"
            
            test_scopes.send(logic) do |scope|
              #puts "TESTING section: #{section.to_s}, scope: #{scope}"
              base_scopes.to_h[section.to_s].to_a.include?(scope.to_s)
            end
          end
        end
        
        def refresh!(*args)
          new_token = super
          new_token.extend Helpers::AccessToken
          new_token
        end
            
      end # AccessToken
    end # Helpers
  
  end # Slack
end # OmniAuth

