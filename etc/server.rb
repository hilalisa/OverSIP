#
# OverSIP - Server Logic.
#




### Custom Application Code:


# Define here your custom code for the application running on top of OverSIP.
# Here you can load thirdy-party libraries and so on.
#
# require "some-gem"
#
module MyExampleApp
  extend ::OverSIP::Logger

  # Custom configuration options:

  # Set this to _true_ if the SIP registrar behind OverSIP does not support Path.
  SIP_USE_MODULE_REGISTRAR_WITHOUT_PATH = true

  # Set this to _true_ if the SIP proxy/server behind OverSIP performing the authentication
  # is ready to accept a P-Asserted-Identity header from OverSIP indicating the already
  # asserted SIP user of the client's connection (this avoids authenticating all the requests
  # but the first one).
  SIP_USE_MODULE_USER_ASSERTION = true
end




### OverSIP System Events:


# This method is called once the OverSIP reactor has been started.
#
# def (OverSIP::SystemEvents).on_started
#   [...]
# end


# This method is called when a USR1 signal is received by OverSIP main
# process and allows the user to set custom code to be executed
# or reloaded.
#
# def (OverSIP::SystemEvents).on_user_reload
#   [...]
# end




### OverSIP SIP Events:


# This method is called when a SIP request is received.
#
def (OverSIP::SipEvents).on_request request

  log_info "#{request.sip_method} from #{request.from.uri} (UA: #{request.header("User-Agent")}) to #{request.ruri} via #{request.transport.upcase} #{request.source_ip} : #{request.source_port}"

  # Check Max-Forwards value (max 10).
  return unless request.check_max_forwards 10

  # Assume all the traffic is from clients and help them with NAT issues
  # by forcing rport usage and Outbound mechanism.
  request.fix_nat

  # In-dialog requests.
  if request.in_dialog?
    if request.loose_route
      log_debug "proxying in-dialog #{request.sip_method}"
      proxy = ::OverSIP::SIP::Proxy.new :proxy_in_dialog
      proxy.route request
    else
      unless request.sip_method == :ACK
        log_notice "forbidden in-dialog request without top Route pointing to us => 403"
        request.reply 403, "forbidden in-dialog request without top Route pointing to us"
      else
        log_notice "ignoring not loose routing ACK"
      end
    end
    return
  end

  # Initial requests.

  # Check that the request does not contain a top Route pointing to another server.
  if request.loose_route
    unless request.sip_method == :ACK
      log_notice "pre-loaded Route not allowed here => 403"
      request.reply 403, "Pre-loaded Route not allowed"
    else
      log_notice "ignoring ACK initial request"
    end
    return
  end

  if MyExampleApp::SIP_USE_MODULE_REGISTRAR_WITHOUT_PATH
    # Extract the Outbound flow token from the RURI.
    OverSIP::SIP::Modules::RegistrarWithoutPath.extract_outbound_from_ruri request
  end

  # The request goes to a client using Outbound through OverSIP.
  if request.incoming_outbound_requested?
    log_info "routing initial request to an Outbound client"

    proxy = ::OverSIP::SIP::Proxy.new :proxy_to_users

    proxy.on_success_response do |response|
      log_info "incoming Outbound on_success_response: #{response.status_code} '#{response.reason_phrase}'"
    end

    proxy.on_failure_response do |response|
      log_info "incoming Outbound on_failure_response: #{response.status_code} '#{response.reason_phrase}'"
    end

    # on_error() occurs when no SIP response was received fom the peer and, instead, we
    # got some other internal error (timeout, connection error, DNS error....).
    proxy.on_error do |status, reason|
      log_notice "incoming Outbound on_error: #{status} '#{reason}'"
    end

    # Route the request and return.
    proxy.route request
    return
  end

  # An initial request with us (OverSIP) as final destination, ok, received, bye...
  if request.destination_myself?
    log_info "request for myself => 404"
    request.reply 404, "Ok, I'm here"
    return
  end

  # An outgoing initial request.
  case request.sip_method

  when :INVITE, :MESSAGE, :OPTIONS, :SUBSCRIBE, :PUBLISH

    if MyExampleApp::SIP_USE_MODULE_USER_ASSERTION
      ::OverSIP::SIP::Modules::UserAssertion.add_pai request
    end

    proxy = ::OverSIP::SIP::Proxy.new :proxy_out

    proxy.on_provisional_response do |response|
      log_info "on_provisional_response: #{response.status_code} '#{response.reason_phrase}'"
    end

    proxy.on_success_response do |response|
      log_info "on_success_response: #{response.status_code} '#{response.reason_phrase}'"
    end

    proxy.on_failure_response do |response|
      log_info "on_failure_response: #{response.status_code} '#{response.reason_phrase}'"
    end

    proxy.on_error do |status, reason|
      log_notice "on_error: #{status} '#{reason}'"
    end

    proxy.route request
    return

  when :REGISTER

    if MyExampleApp::SIP_USE_MODULE_REGISTRAR_WITHOUT_PATH
      # Contact mangling for the case in which the registrar does not support Path.
      ::OverSIP::SIP::Modules::RegistrarWithoutPath.add_outbound_to_contact request
    end

    proxy = ::OverSIP::SIP::Proxy.new :proxy_out

    proxy.on_success_response do |response|
      if MyExampleApp::SIP_USE_MODULE_REGISTRAR_WITHOUT_PATH
        # Undo changes done to the Contact header provided by the client, so it receives
        # the same value in the 200 response from the registrar.
        ::OverSIP::SIP::Modules::RegistrarWithoutPath.remove_outbound_from_contact response
      end

      if MyExampleApp::SIP_USE_MODULE_USER_ASSERTION
        # The registrar replies 200 after a REGISTER with credentials so let's assert
        # the current SIP user to this connection.
        ::OverSIP::SIP::Modules::UserAssertion.assert_connection response
      end
    end

    proxy.on_failure_response do |response|
      if MyExampleApp::SIP_USE_MODULE_USER_ASSERTION
        # We don't add PAI for re-REGISTER, so 401 will be replied, and after it let's
        # revoke the current user assertion (will be re-added upon REGISTER with credentials).
        ::OverSIP::SIP::Modules::UserAssertion.revoke_assertion response
      end
    end

    proxy.route request
    return

  else

    log_info "method #{request.sip_method} not implemented => 501"
    request.reply 501, "Not Implemented"
    return

  end
end




### OverSIP WebSocket Events:


# This method is called when a new WebSocket connection is being requested.
# Here you can inspect the connection and the HTTP GET request. If you
# decide not to accept this connection then call to:
#
#   connection.http_reject(status_code, reason_phrase=nil, extra_headers=nil)
#
# You can also set variables for this connection via the connection.cvars
# Hash. Later you can access to this Hash in SIP requests from this connection
# by retrieving request.cvars attribute.
#
# def (OverSIP::WebSocketEvents).on_connection connection, http_request
#   [...]
# end


# This method is called when a WebSocket connection is closed.
#
# def (OverSIP::WebSocketEvents).on_connection_closed connection
#   [...]
# end