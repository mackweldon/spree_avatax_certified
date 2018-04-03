require 'json'
require 'net/http'
require 'addressable/uri'
require 'base64'
require 'logger'

module SpreeAvataxCertified
  class Address

    attr_reader :order, :addresses

    def initialize(order)
      @order = order
      @ship_address = order.ship_address
      @origin_address = JSON.parse(Spree::Config.avatax_origin)
      @addresses = []

      @logger ||= AvataxHelper::AvataxLog.new('avalara_order_addresses', 'SpreeAvataxCertified::Address', 'building addresses')

      build_addresses
    end

    def build_addresses
      origin_address
      order_ship_address unless @ship_address.nil?
      origin_ship_addresses
    end

    def origin_address
      orig_address = {
        AddressCode: 'Orig',
        Line1: @origin_address['Address1'],
        Line2: @origin_address['Address2'],
        City: @origin_address['City'],
        Region: @origin_address['Region'],
        PostalCode: @origin_address['Zip5'],
        Country: @origin_address['Country']
      }

      @logger.debug orig_address

      addresses << orig_address
    end

    def order_ship_address
      shipping_address = {
        AddressCode: 'Dest',
        Line1: @ship_address.address1,
        Line2: @ship_address.address2,
        City: @ship_address.city,
        Region: @ship_address.state_name,
        Country: @ship_address.country.try(:iso),
        PostalCode: @ship_address.zipcode
      }

      @logger.debug shipping_address

      addresses << shipping_address
    end

    def origin_ship_addresses
      Spree::StockLocation.where(id: stock_loc_ids).each do |stock_location|
        addresses << {
          AddressCode: "#{stock_location.id}",
          Line1: stock_location.address1,
          Line2: stock_location.address2,
          City: stock_location.city,
          PostalCode: stock_location.zipcode,
          Country: stock_location.country.try(:iso)
        }
      end
    end

    def validate
      address = order.ship_address
      if address_validation_enabled? && country_enabled?(Spree::Country.find(address[:country_id]))

        return address if address.nil?

        address_hash = {
          Line1: address[:address1],
          Line2: address[:address2],
          City: address[:city],
          Region: Spree::State.find(address[:state_id]).abbr,
          Country: Spree::Country.find(address[:country_id]).iso,
          PostalCode: address[:zipcode]
        }

        encodedquery = Addressable::URI.new
        encodedquery.query_values = address_hash
        uri = URI(service_url + encodedquery.query)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE

        res = http.get(uri.request_uri, 'Authorization' => credential)

        response = JSON.parse(res.body)

        if response["Address"]["City"] == address[:city] || response["Address"]["Region"] == Spree::State.find(address[:state_id]).abbr
          return response
        else
          response["ResultCode"] = "Error"
          suggested_address = response["Address"]
          response["Messages"] = [{
                                    "Summary" => "Did you mean #{suggested_address['Line1']}, #{suggested_address['City']}, #{suggested_address['Region']}, #{suggested_address['PostalCode']}?"
          }]
          return response
        end
      else
        "Address validation disabled"
      end
    rescue => e
      'error in address validation'
    end

    def address_validation_enabled?
      Spree::Config.avatax_address_validation
    end

    def country_enabled?(current_country)
      Spree::Config.avatax_address_validation_enabled_countries.any? { |country| current_country.name == country }
    end

    private

    def credential
      'Basic ' + Base64.encode64(account_number + ":" + license_key)
    end

    def service_url
      Spree::Config.avatax_endpoint + AVATAX_SERVICEPATH_ADDRESS + 'validate?'
    end

    def license_key
      Spree::Config.avatax_license_key
    end

    def account_number
      Spree::Config.avatax_account
    end

    def stock_loc_ids
      order.shipments.pluck(:stock_location_id).uniq
    end
  end
end
