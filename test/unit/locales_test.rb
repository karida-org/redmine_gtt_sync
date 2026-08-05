# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

class RedmineGttSyncLocalesTest < ActiveSupport::TestCase
  LOCALE_DIR = File.expand_path('../../config/locales', __dir__)

  def locale_keys(locale)
    YAML.load_file(File.join(LOCALE_DIR, "#{locale}.yml")).fetch(locale).keys.sort
  end

  def test_en_and_ja_define_the_same_keys
    # Every string ships in both languages; a key added to one file only
    # fails here instead of falling back to English silently in production.
    assert_equal locale_keys('en'), locale_keys('ja')
  end
end
