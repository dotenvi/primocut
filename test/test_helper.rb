ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Swap a singleton method for the duration of a block, then put it back.
    #
    # Minitest 6 no longer ships `minitest/mock`, and this project carries no
    # mocking gem — services take their dependencies through the constructor
    # precisely so fakes can be injected instead. This covers the one seam a
    # constructor cannot reach: a class method a controller calls to build its
    # own client (`Adapters::YoutubeApi.from_env`), which must never hit the
    # network from a test.
    def stubbing(owner, name, value)
      original = owner.method(name)
      owner.define_singleton_method(name) { |*, **, &_block| value }
      yield
    ensure
      owner.singleton_class.undef_method(name)
      owner.define_singleton_method(name, original)
    end
  end
end
