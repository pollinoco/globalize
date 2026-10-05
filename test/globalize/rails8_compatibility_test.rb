# encoding: utf-8
require File.expand_path('../../test_helper', __FILE__)

class Rails8CompatibilityTest < Minitest::Spec
  def capture_sql
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      next if sql.empty?
      next if payload[:name] == "SCHEMA"
      next if sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      queries << sql
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  describe "attribute reads" do
    it "resolves translated columns when the name is a string" do
      expected = Post.translation_class.columns_hash["title"]
      assert_equal expected, Post.new.column_for_attribute("title")
      assert_equal expected, Post.new.column_for_attribute(:title)
    end

    it "does not query to answer changed? when translations are not loaded" do
      post = Post.create!(:title => "hello")
      post.reload

      queries = capture_sql { refute post.changed? }
      assert_empty queries
    end

    it "does not build an empty translation while computing the cache key" do
      post = Post.create!(:title => "hello")
      post.translations.load
      size = post.translations.size

      Globalize.with_locale(:de) { refute_nil post.cache_key }

      assert_equal size, post.translations.size
    end

    it "does not update the translation when the value is unchanged" do
      post = Post.create!(:title => "same")
      post.reload

      queries = capture_sql { post.update!(:title => "same") }
      refute queries.any? { |sql| sql.match?(/UPDATE/i) && sql.match?(/post_translations/i) }
    end
  end

  describe "fallback queries" do
    before do
      @previous_fallbacks = Globalize.send(:read_fallbacks).dup
      Globalize.fallbacks = { :en => [:en, :de] }
    end

    after do
      Globalize.fallbacks = @previous_fallbacks
    end

    it "filters with EXISTS and counts parent rows once" do
      post = Post.create!(:title => "shared")
      Globalize.with_locale(:de) { post.update!(:title => "shared") }
      Post.create!(:title => "other")

      relation = Post.where(:title => "shared")
      assert_match(/EXISTS/i, relation.to_sql)
      refute_match(/DISTINCT/i, relation.to_sql)
      assert_equal [], relation.joins_values
      assert_equal 1, relation.count
      assert_equal [post], relation.to_a
    end

    it "excludes a record when any fallback locale matches where.not" do
      hidden = Post.create!(:title => "keep")
      Globalize.with_locale(:de) { hidden.update!(:title => "drop") }
      visible = Post.create!(:title => "other")

      assert_equal [visible], Post.where.not(:title => "drop").to_a
    end

    it "orders by the current locale before fallbacks without duplicating rows" do
      first = Product.create!(:name => "bravo")
      Globalize.with_locale(:de) { first.update!(:name => "alpha") }
      second = Product.create!(:name => "charlie")

      ordered = Product.order(:name).to_a
      assert_equal [first, second], ordered
      assert_equal Product.count, ordered.size
    end

    it "rewrites order('title ASC') onto the translations table" do
      sql = Post.order("title ASC").to_sql
      assert_match(/ORDER BY \(SELECT/i, sql)
      assert_match(/post_translations/i, sql)
    end
  end
end
