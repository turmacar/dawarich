# frozen_string_literal: true

module TransportationModes
  # Queries the configured geocoder (Photon) near a track's origin and destination
  # to produce per-mode log-likelihood boosts for the Viterbi decoder.
  #
  # Strategy:
  #   Origin  - last stationary burst before the track begins (the parked phase
  #             at a departure airport or station). Falls back to the track's
  #             first point when no stationary burst is found.
  #   Destination - last point of the track.
  #
  # The result is a flat {mode => Float} hint merged into every window, so the
  # Decoder sees it as consistent evidence throughout the whole track rather
  # than a single-window spike.
  #
  # Boost values are in log-space and calibrated against MODE_PRIORS:
  #   flying prior = -2.5  ->  AEROWAY_BOOST = 3.5 yields a net +1.0 head-start
  #   train  prior = -1.75 ->  RAILWAY_BOOST = 2.5 yields a net +0.75 head-start
  class SpatialHintEnricher
    # OSM aeroway values that confirm a traveler is AT an airport
    AEROWAY_PORTS = %w[terminal aerodrome airfield airport heliport gate hangar].freeze
    # OSM railway values that confirm a traveler is AT a station
    RAILWAY_PORTS = %w[station halt stop tram_stop].freeze

    AEROWAY_BOOST = 3.5
    RAILWAY_BOOST = 2.5

    # Radius passed to Geocoder (km). Large enough to catch an airport when
    # the last stationary point is on the taxiway or approach road.
    SEARCH_RADIUS_KM = 2.0
    SEARCH_LIMIT = 7

    # Velocity threshold (km/h) below which a point counts as "stationary".
    STATIONARY_KMH = 5.0
    # How many of the track's leading points to scan for a stationary burst.
    ORIGIN_SCAN_POINTS = 30

    def self.call(track)
      return {} unless DawarichSettings.reverse_geocoding_enabled?

      hints = {}
      [origin_lonlat(track), destination_lonlat(track)].compact.uniq.each do |lo
nlat|
        detected = spatial_hints_at(lonlat)
        hints.merge!(detected) { |_k, a, b| [a, b].max }
      end
      hints
    end

    def self.origin_lonlat(track)
      # Prefer the last slow/stationary point at the start of the track
      # (the parked phase at a departure airport or station).
      stationary = track.points
                        .order(:timestamp)
                        .limit(ORIGIN_SCAN_POINTS)
                        .select { |p| velocity_kmh(p) < STATIONARY_KMH }
                        .last
      pt = stationary || track.points.order(:timestamp).first
      lonlat_from_point(pt)
    end

    def self.destination_lonlat(track)
      lonlat_from_point(track.points.order(:timestamp).last)
    end

    def self.lonlat_from_point(point)
      return nil unless point&.lonlat

      lon = point.lonlat.lon
      lat = point.lonlat.lat
      return nil if lon.nil? || lat.nil? || (lon.zero? && lat.zero?)

      [lat, lon]
    end

    def self.velocity_kmh(point)
      return Float::INFINITY unless point.velocity.present?

      Float(point.velocity)
    rescue ArgumentError
      Float::INFINITY
    end

    def self.spatial_hints_at(latlon)
      results = Geocoder.search(latlon, limit: SEARCH_LIMIT, radius: SEARCH_RADIUS_KM, units: :km)
      return {} if results.blank?

      hints = {}
      results.each do |result|
        props = result.data['properties'] || {}
        key   = props['osm_key'].to_s
        value = props['osm_value'].to_s

        if key == 'aeroway' && AEROWAY_PORTS.include?(value)
          hints[:flying] = [hints[:flying].to_f, AEROWAY_BOOST].max
          break
        end

        if key == 'railway' && RAILWAY_PORTS.include?(value)
          hints[:train] = [hints[:train].to_f, RAILWAY_BOOST].max
          break
        end
      end
      hints
    rescue StandardError => e
      Rails.logger.warn("SpatialHintEnricher failed at #{latlon.inspect}: #{e.cl
ass}: #{e.message}")
      {}
    end

    private_class_method :origin_lonlat, :destination_lonlat, :lonlat_from_point,
                         :velocity_kmh, :spatial_hints_at
  end
end
