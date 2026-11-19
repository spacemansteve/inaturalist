# frozen_string_literal: true

require "delegate"

module Surveys
  # Preserve PostGIS casting and serialization. Rails 6.1's SQL logger does not
  # honor filter_attributes for binds; marking this EWKB value as binary uses
  # its built-in byte-count redaction, including EXPLAIN bind rendering.
  class GeometryType < SimpleDelegator
    def binary?
      true
    end
  end
end
