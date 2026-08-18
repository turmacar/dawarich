# frozen_string_literal: true

require "rails_helper"

RSpec.describe TransportationModes::SpatialHintEnricher do
  let(:user) { create(:user) }
  let(:track) { create(:track, user: user) }

  def make_point(lat:, lon:, velocity: "0")
    create(:point, track: track, user: user, velocity: velocity,
           lonlat: "SRID=4326;POINT(#{lon} #{lat})")
  end

  describe ".call" do
    context "when reverse geocoding is disabled" do
      before { allow(DawarichSettings).to receive(:reverse_geocoding_enabled?).and_return(false) }

      it "returns empty hints without calling Geocoder" do
        expect(Geocoder).not_to receive(:search)
        expect(described_class.call(track)).to eq({})
      end
    end

    context "when reverse geocoding is enabled" do
      before { allow(DawarichSettings).to receive(:reverse_geocoding_enabled?).and_return(true) }

      context "when Photon returns an aeroway:terminal near the origin" do
        before do
          make_point(lat: 47.622, lon: -117.534, velocity: "0") # parked at airport
          make_point(lat: 47.700, lon: -117.400, velocity: "180") # in flight

          aeroway_result = instance_double(Geocoder::Result::Photon,
                                           data: { "properties" => { "osm_key" => "aeroway",
                                                                      "osm_value" => "terminal" } })
          allow(Geocoder).to receive(:search).and_return([aeroway_result])
        end

        it "returns a flying hint with AEROWAY_BOOST" do
          hints = described_class.call(track)
          expect(hints[:flying]).to eq(described_class::AEROWAY_BOOST)
        end

        it "does not return a train hint" do
          expect(described_class.call(track)).not_to have_key(:train)
        end
      end

      context "when Photon returns a railway:station near the origin" do
        before do
          make_point(lat: 47.660, lon: -117.426, velocity: "0")
          make_point(lat: 47.800, lon: -117.300, velocity: "120")

          station_result = instance_double(Geocoder::Result::Photon,
                                           data: { "properties" => { "osm_key" => "railway",
                                                                      "osm_value" => "station" } })
          allow(Geocoder).to receive(:search).and_return([station_result])
        end

        it "returns a train hint with RAILWAY_BOOST" do
          hints = described_class.call(track)
          expect(hints[:train]).to eq(described_class::RAILWAY_BOOST)
        end
      end

      context "when Photon returns only road features" do
        before do
          make_point(lat: 47.700, lon: -117.400, velocity: "0")
          road_result = instance_double(Geocoder::Result::Photon,
                                        data: { "properties" => { "osm_key" => "highway",
                                                                   "osm_value" => "tertiary" } })
          allow(Geocoder).to receive(:search).and_return([road_result])
        end

        it "returns empty hints" do
          expect(described_class.call(track)).to eq({})
        end
      end

      context "when Geocoder raises" do
        before do
          make_point(lat: 47.700, lon: -117.400, velocity: "0")
          allow(Geocoder).to receive(:search).and_raise(StandardError, "timeout")
        end

        it "returns empty hints and logs a warning" do
          expect(Rails.logger).to receive(:warn).with(/SpatialHintEnricher failed/)
          expect(described_class.call(track)).to eq({})
        end
      end
    end
  end

  describe ".origin_lonlat" do
    before { allow(DawarichSettings).to receive(:reverse_geocoding_enabled?).and_return(true) }

    it "prefers the last stationary point among the first ORIGIN_SCAN_POINTS points" do
      make_point(lat: 47.622, lon: -117.534, velocity: "0")   # parked (stationary)
      make_point(lat: 47.650, lon: -117.500, velocity: "120") # rolling
      make_point(lat: 47.700, lon: -117.400, velocity: "200") # flying

      allow(Geocoder).to receive(:search).and_return([])
      described_class.call(track)

      # The stationary point at the airport should be probed
      expect(Geocoder).to have_received(:search)
        .with([47.622, -117.534], hash_including(radius: described_class::SEARCH_RADIUS_KM))
        .at_least(:once)
    end
  end
end
