require File.expand_path('test_helper.rb', 'test')

class GET_baseurl < MiniTest::Unit::TestCase
  include Rack::Test::Methods

  def setup
    get '/'
  end

  def test_succeeds
    assert last_response.status, 200
  end

  def test_returns_valid_json
    assert_equal json_response.first['type'], 'Directory'
  end
end
