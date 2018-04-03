module SpreeAvataxCertified
  class Line
    attr_reader :order, :invoice_type, :lines, :refund

    def initialize(order, invoice_type, refund = nil)
      @logger ||= AvataxHelper::AvataxLog.new('avalara_order_lines', 'SpreeAvataxCertified::Line', 'building lines')
      @order = order
      @invoice_type = invoice_type
      @lines = []
      @refund = refund

      build_lines
      @logger.debug @lines
    end

    def build_lines
      if %w(ReturnInvoice ReturnOrder).include?(invoice_type)
        refund_lines
      else
        item_lines_array
        shipment_lines_array
      end
    end

    def item_line(line_item)
      {
        :LineNo => "#{line_item.id}-LI",
        :Description => line_item.name[0..255],
        :TaxCode => line_item.tax_category.try(:tax_code) || 'P0000000',
        :ItemCode => line_item.variant.sku,
        :Qty => line_item.quantity,
        :Amount => line_item.amount.to_f,
        :OriginCode => get_stock_location(line_item),
        :DestinationCode => 'Dest',
        :CustomerUsageType => customer_usage_type,
        :Discounted => line_item.discountable?
      }
    end

    def item_lines_array
      order.line_items.each do |line_item|
        lines << item_line(line_item)
      end
    end

    def shipment_lines_array
      order.shipments.each do |shipment|
        next unless shipment.tax_category
        lines << shipment_line(shipment)
      end
    end

    def shipment_line(shipment)
      {
        :LineNo => "#{shipment.id}-FR",
        :ItemCode => shipment.shipping_method.name,
        :Qty => 1,
        :Amount => shipment.discounted_amount.to_f,
        :OriginCode => "#{shipment.stock_location_id}",
        :DestinationCode => 'Dest',
        :CustomerUsageType => customer_usage_type,
        :Description => 'Shipping Charge',
        :TaxCode => shipment.shipping_method.tax_category.try(:tax_code) || 'FR000000'
      }
    end

    def refund_lines
      refunds = []
      if refund.reimbursement.nil?
        # raise "SpreeAvataxCertified#refund_lines called on a refund, but the refund is not attached to a reimbursement"

        unless refund.try(:try_on_guarantee_request_id).nil?
          tog_item = TryOnGuaranteeRequest.find(refund.try_on_guarantee_request_id)
          amount = tog_item.pre_tax_amount
          line_item = tog_item.inventory_unit.line_item

          refunds << tog_item_line(line_item, amount)

        else
          refunds << refund_line
        end

      else
        return_items = refund.reimbursement.customer_return.return_items
        amount = return_items.sum(:pre_tax_amount) / Spree::InventoryUnit.where(id: return_items.pluck(:inventory_unit_id)).select(:line_item_id).uniq.count

        return_items.map(&:inventory_unit).group_by(&:line_item_id).each_value do |inv_unit|
          quantity = inv_unit.uniq.count
          refunds << return_item_line(inv_unit.first.line_item, quantity, amount)
        end
      end

      @logger.debug refunds
      lines.concat(refunds) unless refunds.empty?
      refunds
    end

    def tog_item_line(line_item, amount)
      {
        :LineNo => "#{line_item.id}-TOG",
        :Description => line_item.name[0..255],
        :TaxCode => line_item.tax_category.try(:description) || 'PC040100',
        :ItemCode => line_item.variant.sku,
        :Qty => 1,
        :Amount => -amount.to_f,
        :OriginCode => 'Orig',
        :DestinationCode => 'Dest',
        :CustomerUsageType => customer_usage_type
      }
    end

    def refund_line
      {
        LineNo: "#{refund.id}-RA",
        ItemCode: refund.transaction_id || 'Refund',
        TaxCode: 'PC040100',
        Qty: 1,
        Amount: -refund.amount.to_f,
        OriginCode: 'Orig',
        DestinationCode: 'Dest',
        CustomerUsageType: customer_usage_type,
        Description: 'Refund'
      }
    end

    def return_item_line(line_item, quantity, amount)
      {
        :LineNo => "#{line_item.id}-LI",
        :Description => line_item.name[0..255],
        :TaxCode => line_item.tax_category.try(:description) || 'PC040100',
        :ItemCode => line_item.variant.sku,
        :Qty => quantity,
        :Amount => -amount.to_f,
        :OriginCode => get_stock_location(line_item),
        :DestinationCode => 'Dest',
        :CustomerUsageType => customer_usage_type
      }
    end

    def get_stock_location(li)
      inventory_units = li.inventory_units

      return 'Orig' if inventory_units.blank?

      # What if inventory units have different stock locations?
      stock_loc_id = inventory_units.first.try(:shipment).try(:stock_location_id)

      stock_loc_id.nil? ? 'Orig' : "#{stock_loc_id}"
    end

    def customer_usage_type
      order.user ? order.user.avalara_entity_use_code.try(:use_code) : ''
    end
  end
end
