module Cuts
  # Drop a slot from the composition. Its clip goes with it (the association
  # cascades), and the remaining positions are packed so the running order stays
  # contiguous.
  class RemoveItem
    def call(cut:, id:)
      item = cut.cut_items.find(id)
      item.destroy!
      Positions.repack!(cut)
      item
    end
  end
end
