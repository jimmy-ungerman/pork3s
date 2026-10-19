# frozen_string_literal: true

# sidekiq-cron 2.3.0 calls Hash#merge on pipelined HGETALL results. Dragonfly
# v1.40+ answers in RESP3 flat-array form ([k, v, k, v, ...]), which breaks
# Sidekiq::Cron::Job.all with NoMethodError. Normalize back to a Hash.
# Remove once sidekiq-cron ships the fix and Sure picks it up:
#   https://github.com/sidekiq-cron/sidekiq-cron/issues/579
#   https://github.com/sidekiq-cron/sidekiq-cron/pull/580
require "sidekiq/cron/job" unless defined?(Sidekiq::Cron::Job)

Sidekiq::Cron::Job.singleton_class.prepend(Module.new do
  def all(namespace = Sidekiq::Cron.configuration.default_namespace)
    job_hashes = nil
    Sidekiq.redis do |conn|
      job_keys = job_keys_from_namespace(namespace)
      job_hashes = conn.pipelined do |pipeline|
        job_keys.each { |job_key| pipeline.hgetall(job_key) }
      end
    end

    job_hashes = job_hashes.map { |h| h.is_a?(Array) ? h.each_slice(2).to_h : h }

    job_hashes.compact.reject(&:empty?).map do |h|
      Sidekiq::Cron::Job.new(h.merge(fetch_missing_args: false))
    end
  end
end)
