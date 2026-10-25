require "../semantic/effects"

module Iyi::Stale
  module Check
    def self.closure_check(program : Program, reach : Reach) : Effects::ClosureResult
      Effects.closure_check(program, reach)
    end
  end
end
