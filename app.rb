require "sinatra/base"
require 'sinatra/synchrony'
require "omniauth-openid"
require "sinatra/config_file"
require "sinatra/multi_route"

require 'redis/connection/hiredis'
require 'redis/connection/synchrony'
require 'redis'
require 'rack/fiber_pool'

require 'uri'
require 'ipaddr'

$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG

class Auth < Sinatra::Base
  set :protection, :except => :path_traversal
  set :static, :false
  register Sinatra::ConfigFile
  config_file 'config/config.yml'

  register Sinatra::MultiRoute

  def initialize
    super
    @redis = EventMachine::Synchrony::ConnectionPool.new(size: 4) do
      Redis.new(:host => settings.redis["host"],:port=>settings.redis["port"],:db=>settings.redis["db"])
    end
  end

  # Use a wildcard cookie to achieve single sign-on for all subdomains
  use Rack::Session::Cookie, :secret => settings.cookie["secret"],
    :domain => settings.cookie["domain"],
    :secure => true

  # Perform authentication against Google OpenID endpoint
  use OmniAuth::Builder do
    provider :open_id, :name => 'google', :identifier => 'https://www.google.com/accounts/o8/id'
  end

  # Catch all requests
  route :get, :post, '*' do
    #
    if request.host == settings.auth_domain
      if request.scheme == "http"
        headers "X-Accel-Redirect" => "/secure"
        return ""
      end
      pass
    end

    # Destroy transmitted key if over HTTP
    if key = params[:authkey]
      if request.scheme == "http"
        status 403
        @redis.del("authkey:#{key}")
        @message = "This authentication key was transmitted over HTTP and was removed from our registry as it may have been compromised."
        return erb :forbidden
      end
    end

    # Do we have a mapping for this
    if url = map(request)
    else
      status 404
      return  erb :nothing
    end

    # Serve website securely?
    if ssl?(request)
      if request.scheme == "http"
        headers "X-Accel-Redirect" => "/secure"
        headers "Content-Type" => ""
        return ""
      end
    end

    unless public?(request)
      # Site is not public
      unless key_access?(request)
        # Access with key is denied
        unless ip_access?(request)
          # Access by IP is denied

          unless authenticated?
            # User not authenticated via omniauth
            redirect settings.auth_domain_proto + "://" + settings.auth_domain + "/?origin=" + CGI.escape(request.url)
          end

          # At this stage, user is logged in via omniauth
          if authorized?(request,"email:#{session[:email]}")
            headers "X-Remote-User" => session[:email]
          else
            status 403
            return erb :forbidden
          end
        end
      end
    end

    # Reaching this point means the user is authorized
    headers "X-Reproxy-URL" => url+request.fullpath
    headers "X-Accel-Redirect" => "/reproxy"
    headers "Content-Type" => ""
    return ""
  end

  # Block that is called back when authentication is successful
  process = lambda do
    auth = request.env['omniauth.auth']
    session[:logged] = true
    session[:provider] = auth.provider
    session[:uid] = auth.uid
    session[:name] = auth.info.name
    session[:email] = auth.info.email

    # Check IP
    if request.env.has_key? 'HTTP_X_FORWARDED_FOR'
      session[:remote_ip] = request.env['HTTP_X_FORWARDED_FOR']
    else
      session[:remote_ip] = request.env['HTTP_X_REAL_IP']
    end

    redirect request.env['omniauth.origin'] || "/"
  end

  get '/auth/:name/callback', &process
  post '/auth/:name/callback', &process

  get '/logout' do
    session.clear
    redirect "/"
  end

  get '/' do
    @origin = CGI.escape(params[:origin]) if params[:origin]
    @authenticated = authenticated?
    erb :login
  end

  def map(req)
    url = @redis.hget(req.host,"url")
    return url
  end

  def ssl?(req)
    secure = @redis.hget(req.host,"ssl") == "false" ? false:true
    return secure
  end

  def public?(req)
    public = @redis.hget(req.host,"public") == "true" ? true:false
    return public
  end

  def key_access?(request)
    # Check whether the request is signed with an authentication key
    if key = params[:authkey]
      # If authorized, serve request
      return authorized?(request,"authkey:#{key}")
    end
  end

  def ip_access?(request)
    $log.debug("Checking IP access")
    check_remote_ip = nil
    if request.env.has_key? 'HTTP_X_FORWARDED_FOR'
      check_remote_ip = request.env['HTTP_X_FORWARDED_FOR']
    else
      check_remote_ip = request.env['HTTP_X_REAL_IP']
    end
    $log.debug("Remote IP is: #{check_remote_ip}")
    # Match IP with netmask
    request_ip = IPAddr.new(check_remote_ip)
    @redis.keys('ip:*').each do |i|
      ip = IPAddr.new(i.gsub(/^ip:/,''))
      if ip.include?(request_ip)
        $log.debug("IP is included in #{i}")
        if authorized?(request,i)
          $log.debug("Access authorized by IP")
          return true
        end
      end
    end

    return false
  end
end

def authenticated?
  check_remote_ip = nil
  if request.env.has_key? 'HTTP_X_FORWARDED_FOR'
    check_remote_ip = request.env['HTTP_X_FORWARDED_FOR']
  else
    check_remote_ip = request.env['HTTP_X_REAL_IP']
  end
  if session[:logged] == true and session[:remote_ip] == check_remote_ip
    return true
  else
    return false
  end
end

# Return internal URL or false if unauthorized
def authorized?(request,entry)
  url = request.url.gsub(/^https?:\/\//,'')
  # Check whether the email address is authorized
  @redis.smembers(entry).each do |reg|
    begin
      $log.debug("Checking #{url} versus #{reg}")
      return true if !!(Regexp.new(reg) =~ url)
    rescue
      $log.error("Malformed regex expressions in database")
    end
  end
  return false
end