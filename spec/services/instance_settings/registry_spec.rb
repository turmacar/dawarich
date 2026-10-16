# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InstanceSettings::Registry do
  describe '.keys' do
    it 'declares the geocoding keys and the backup keys' do
      expect(described_class.keys).to contain_exactly(
        :photon_api_host, :photon_api_key, :photon_api_use_https,
        :nominatim_api_host, :nominatim_api_key, :nominatim_api_use_https,
        :geoapify_api_key, :locationiq_api_key,
        :reverse_geocoding_rps, :store_geodata,
        :backup_export_frequency, :backup_export_path,
        :backup_export_retention, :backup_database_dump
      )
    end
  end

  describe '.fetch' do
    it 'raises KeyError for an unknown key rather than returning nil' do
      expect { described_class.fetch(:no_such_setting) }.to raise_error(KeyError)
    end

    it 'maps each key to the environment variable it has always used' do
      expect(described_class.fetch(:photon_api_host).env_var).to eq('PHOTON_API_HOST')
      expect(described_class.fetch(:store_geodata).env_var).to eq('STORE_GEODATA')
      expect(described_class.fetch(:reverse_geocoding_rps).env_var).to eq('REVERSE_GEOCODING_RPS')
    end
  end

  describe 'defaults' do
    it 'preserves the boolean defaults the constants shipped with' do
      expect(described_class.fetch(:store_geodata).default).to be(true)
      expect(described_class.fetch(:photon_api_use_https).default).to be(false)
      expect(described_class.fetch(:nominatim_api_use_https).default).to be(true)
    end

    it 'defaults the rate ceiling to nil, meaning unlimited' do
      expect(described_class.fetch(:reverse_geocoding_rps).default).to be_nil
    end

    it 'ships scheduled backups switched off, with no destination and seven kept' do
      expect(described_class.fetch(:backup_export_frequency).default).to eq('off')
      expect(described_class.fetch(:backup_export_path).default).to be_nil
      expect(described_class.fetch(:backup_export_retention).default).to eq(7)
      expect(described_class.fetch(:backup_database_dump).default).to be(false)
    end

    it 'reads a blank retention as the default rather than zero' do
      expect(described_class.fetch(:backup_export_retention).coerce('')).to eq(7)
    end
  end

  describe 'secrets' do
    it 'marks the api keys secret so they route to the encrypted column' do
      %i[photon_api_key nominatim_api_key geoapify_api_key locationiq_api_key].each do |key|
        expect(described_class.fetch(key)).to be_secret, "expected #{key} to be secret"
      end
    end

    it 'does not mark hosts secret' do
      expect(described_class.fetch(:photon_api_host)).not_to be_secret
    end
  end

  describe '#coerce' do
    it 'falls back to the default for a blank numeric value instead of zero' do
      definition = described_class.fetch(:reverse_geocoding_rps)

      expect(definition.coerce('')).to be_nil
      expect(definition.coerce(nil)).to be_nil
    end

    it 'falls back to the default for a non-numeric value instead of zero' do
      expect(described_class.fetch(:reverse_geocoding_rps).coerce('not-a-number')).to be_nil
    end

    it 'parses a well-formed numeric value' do
      expect(described_class.fetch(:reverse_geocoding_rps).coerce('2.5')).to eq(2.5)
    end

    it 'treats only the literal string true as true, matching the old constants' do
      definition = described_class.fetch(:photon_api_use_https)

      expect(definition.coerce('true')).to be(true)
      expect(definition.coerce('yes')).to be(false)
    end

    it 'returns the default for a blank boolean rather than false' do
      expect(described_class.fetch(:store_geodata).coerce('')).to be(true)
    end

    it 'passes strings through stripped' do
      expect(described_class.fetch(:photon_api_host).coerce('  photon.example.com  ')).to eq('photon.example.com')
    end
  end
end
