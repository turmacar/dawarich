# frozen_string_literal: true

module Dawarich
  # Answers every request with a "restoring" page while a database restore runs, so
  # nobody writes to a database that is about to be replaced. The liveness check stays
  # up so the container is not restarted mid-restore.
  class MaintenanceGate
    OPEN_PATHS = ['/api/v1/health'].freeze
    REFRESH_SECONDS = 15

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if OPEN_PATHS.include?(env['PATH_INFO']) || !Backups::Maintenance.active?

      request = Rack::Request.new(env)
      headers = { 'retry-after' => REFRESH_SECONDS.to_s, 'cache-control' => 'no-store' }
      if request.path.start_with?('/api/') || request.media_type == 'application/json'
        [503, headers.merge('content-type' => 'application/json'), [{ error: 'maintenance' }.to_json]]
      else
        [503, headers.merge('content-type' => 'text/html; charset=utf-8'), [page]]
      end
    end

    private

    def page
      title = ERB::Util.html_escape(I18n.t('admin.settings.maintenance.title'))
      body = ERB::Util.html_escape(I18n.t('admin.settings.maintenance.body'))
      <<~HTML
        <!DOCTYPE html>
        <html lang="#{I18n.locale}">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="refresh" content="#{REFRESH_SECONDS}">
            <title>#{title}</title>
            <style>
              body { font-family: system-ui, sans-serif; display: grid; place-items: center; min-height: 100vh;
                     margin: 0; background: #1d232a; color: #a6adbb; }
              main { max-width: 32rem; padding: 2rem; text-align: center; }
              h1 { color: #fff; font-size: 1.25rem; }
            </style>
          </head>
          <body><main><h1>#{title}</h1><p>#{body}</p></main></body>
        </html>
      HTML
    end
  end
end
