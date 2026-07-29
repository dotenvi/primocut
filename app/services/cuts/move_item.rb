module Cuts
  # Move a slot one place up or down. At the edge it is a no-op rather than an
  # error: the control stays where it is and simply does nothing.
  class MoveItem
    def call(cut:, id:, direction:)
      item = cut.cut_items.find(id)
      neighbour = Positions.neighbour(cut, item, direction)
      Positions.swap!(item, neighbour) if neighbour
      item
    end
  end
end
