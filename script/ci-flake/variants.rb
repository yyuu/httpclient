# Diagnostic fixture changes; repository test/helper.rb remains unchanged.
if ENV['JOIN_SERVER_THREADS'] == '1'
  module JoinServerThreads
    def teardown_server
      super
      @server_thread.join if @server_thread
    end

    def teardown_proxyserver
      super
      @proxyserver_thread.join if @proxyserver_thread
    end
  end
  Helper.prepend(JoinServerThreads)
end

if ENV['DRAIN_DIGEST_BODY'] == '1'
  module DrainDigestBody
    def do_digest_auth(request, response)
      request.body
      super
    end
  end
  TestAuth.prepend(DrainDigestBody)
end
