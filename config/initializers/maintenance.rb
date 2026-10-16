# frozen_string_literal: true

require 'dawarich/maintenance_gate'

Rails.application.config.middleware.use Dawarich::MaintenanceGate
