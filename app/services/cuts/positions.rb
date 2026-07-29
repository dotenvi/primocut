module Cuts
  # The ordering rules of a cut's items. Positions are contiguous from zero and
  # carry the running order of the composition, so every mutation has to leave
  # them packed — a gap would make "move down" skip a slot and the render write
  # clips in an order nobody chose.
  module Positions
    module_function

    def next_for(cut) = (cut.cut_items.maximum(:position) || -1) + 1

    # Close the gaps a removal leaves, touching only the rows that actually move.
    def repack!(cut)
      cut.cut_items.reorder(:position).each_with_index do |item, index|
        item.update_column(:position, index) unless item.position == index
      end
    end

    # The item one slot up or down, or nil at the edge.
    def neighbour(cut, item, direction)
      if direction.to_s == "up"
        cut.cut_items.where(position: ...item.position).reorder(position: :desc).first
      else
        cut.cut_items.where(position: (item.position + 1)..).reorder(:position).first
      end
    end

    def swap!(one, other)
      held = one.position
      Cut.transaction do
        one.update!(position: other.position)
        other.update!(position: held)
      end
    end
  end
end
