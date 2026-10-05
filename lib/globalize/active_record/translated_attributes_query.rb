module Globalize
  module ActiveRecord
    class TranslatedAttributesWhereChain < ::ActiveRecord::QueryMethods::WhereChain
      def not(opts, *rest)
        scope = @scope
        if !scope.joins_values.include?(:translations) && (extracted = scope.extract_translated_predicates(opts))
          relation = if extracted[:remaining].empty?
            rest.empty? ? scope : scope.where(*rest)
          else
            scope.where(extracted[:remaining], *rest)
          end
          sql, binds = scope.translated_exists_sql(extracted[:predicates], negate: true)
          relation.where(sql, *binds)
        elsif parsed = scope.parse_translated_conditions(opts)
          scope.join_translations.where.not(parsed, *rest)
        else
          super
        end
      end
    end

    module TranslatedAttributesQuery
      def where(opts = :chain, *rest)
        if opts == :chain
          return TranslatedAttributesWhereChain.new(spawn)
        end

        # EXISTS keeps one parent row per match. Joining every fallback locale
        # multiplies rows and forces DISTINCT, which is expensive on PostgreSQL
        # and makes COUNT wrong or slow. An existing translations join (for
        # example with_translations) still filters that joined row.
        if !joins_values.include?(:translations) && (extracted = extract_translated_predicates(opts))
          relation = if extracted[:remaining].empty?
            rest.empty? ? self : super(*rest)
          else
            super(extracted[:remaining], *rest)
          end
          sql, binds = translated_exists_sql(extracted[:predicates])
          found = relation.where(sql, *binds)
          remember_translated_predicates(found, extracted[:predicates])
          return found
        end

        if parsed = parse_translated_conditions(opts)
          join_translations(super(parsed, *rest))
        else
          super
        end
      end

      def having(opts, *rest)
        if parsed = parse_translated_conditions(opts)
          join_translations(super(parsed, *rest))
        else
          super
        end
      end

      def order(*args)
        rewritten = rewrite_order_args(args)
        rewritten ? super(*rewritten) : super
      end

      def reorder(*args)
        rewritten = rewrite_order_args(args)
        rewritten ? super(*rewritten) : super
      end

      def group(*columns)
        if respond_to?(:translated_attribute_names) && parsed = parse_translated_columns(columns)
          join_translations super(parsed)
        else
          super
        end
      end

      def select(*columns)
        if respond_to?(:translated_attribute_names) && parsed = parse_translated_columns(columns)
          join_translations super(parsed)
        else
          super
        end
      end

      def exists?(conditions = :none)
        if conditions.is_a?(Hash) && respond_to?(:translated_attribute_names) &&
            (conditions.symbolize_keys.keys & translated_attribute_names).present?
          where(conditions).exists?
        else
          super
        end
      end

      def calculate(*args)
        column_name = args[1]
        if respond_to?(:translated_attribute_names) && translated_column?(column_name)
          args[1] = translated_column_name(column_name)
          join_translations.calculate(*args)
        else
          super
        end
      end

      def pluck(*column_names)
        if respond_to?(:translated_attribute_names) && parsed = parse_translated_columns(column_names)
          join_translations.pluck(*parsed)
        else
          super
        end
      end

      def with_translations_in_fallbacks
        with_translations(Globalize.fallbacks)
      end

      def parse_translated_conditions(opts)
        if opts.is_a?(Hash) && respond_to?(:translated_attribute_names) && (keys = opts.symbolize_keys.keys & translated_attribute_names).present?
          opts = opts.dup
          keys.each { |key| opts[translated_column_name(key)] = opts.delete(key) || opts.delete(key.to_s) }
          opts
        end
      end

      # Splits a hash of conditions into translated predicates (matched on one
      # translation row) and the rest, which stay on the parent table.
      # Returns nil when a value cannot be expressed as a bound comparison, so
      # the caller keeps the historical join.
      def extract_translated_predicates(opts)
        return unless opts.is_a?(Hash) && respond_to?(:translated_attribute_names)

        keys = opts.symbolize_keys.keys & translated_attribute_names
        return if keys.empty?

        predicates = {}
        keys.each do |key|
          value = opts.key?(key) ? opts[key] : opts[key.to_s]
          return if unsupported_predicate_value?(value)

          predicates[key] = value
        end

        { predicates: predicates, remaining: opts.except(*keys, *keys.map(&:to_s)) }
      end

      def translated_exists_sql(predicates, negate: false)
        translation = translation_class.quoted_table_name
        parent = quoted_table_name
        foreign_key = connection.quote_column_name(translation_options[:foreign_key])
        parent_key = connection.quote_column_name(scalar_primary_key)
        locale_column = connection.quote_column_name("locale")
        locales = Array(Globalize.fallbacks).map(&:to_s)

        parts = []
        binds = [locales]

        predicates.each do |name, value|
          column = "#{translation}.#{connection.quote_column_name(name)}"
          if value.nil?
            parts << "#{column} IS NULL"
          elsif value.is_a?(Array)
            if value.empty?
              parts << "1=0"
            else
              parts << "#{column} IN (?)"
              binds << value
            end
          else
            parts << "#{column} = ?"
            binds << value
          end
        end

        sql = <<~SQL.squish
          #{'NOT ' if negate}EXISTS (
            SELECT 1 FROM #{translation}
            WHERE #{translation}.#{foreign_key} = #{parent}.#{parent_key}
              AND #{translation}.#{locale_column} IN (?)
              AND #{parts.join(' AND ')}
          )
        SQL
        [sql, binds]
      end

      def remember_translated_predicates(relation, predicates)
        previous = relation.instance_variable_get(:@globalize_predicates) ||
          instance_variable_get(:@globalize_predicates) ||
          {}
        # IN lists are not a single value create can assign.
        assignable = predicates.reject { |_name, value| value.is_a?(Array) }
        relation.instance_variable_set(:@globalize_predicates, previous.merge(assignable))
      end

      def join_translations(relation = self)
        if relation.joins_values.include?(:translations)
          relation
        else
          relation.with_translations_in_fallbacks
        end
      end

      private

      def rewrite_order_args(args)
        return unless respond_to?(:translated_attribute_names)

        changed = false
        rewritten = args.flat_map do |arg|
          parsed = parse_translated_order(arg)
          if parsed
            changed = true
            parsed
          else
            [arg]
          end
        end
        rewritten if changed
      end

      # One scalar subquery per translated column, in fallback order. This does
      # not multiply parent rows, so it stays valid next to GROUP BY id and
      # does not need DISTINCT.
      def fallback_value_sql(column)
        translation = translation_class.quoted_table_name
        parent = quoted_table_name
        foreign_key = connection.quote_column_name(translation_options[:foreign_key])
        parent_key = connection.quote_column_name(scalar_primary_key)
        quoted_column = connection.quote_column_name(column)
        locale_column = connection.quote_column_name("locale")
        locales = Array(Globalize.fallbacks).map(&:to_s)
        locale_list = locales.map { |locale| connection.quote(locale) }.join(", ")
        rank = locales.each_with_index.map { |locale, index|
          "WHEN #{connection.quote(locale)} THEN #{index}"
        }.join(" ")

        <<~SQL.squish
          (SELECT #{translation}.#{quoted_column} FROM #{translation}
           WHERE #{translation}.#{foreign_key} = #{parent}.#{parent_key}
             AND #{translation}.#{locale_column} IN (#{locale_list})
             AND #{translation}.#{quoted_column} IS NOT NULL
             #{blank_fallback_sql(translation, quoted_column, column)}
           ORDER BY CASE #{translation}.#{locale_column} #{rank} END
           LIMIT 1)
        SQL
      end

      def blank_fallback_sql(translation, quoted_column, column)
        return "" unless fallbacks_for_empty_translations

        type = translation_class.columns_hash[column.to_s]&.type
        return "" unless [:string, :text, :citext].include?(type)

        "AND #{translation}.#{quoted_column} <> ''"
      end

      def order_node_for(column, direction)
        dir = normalize_order_direction(direction)
        if translated_column?(column)
          # NULLS LAST keeps records without a translation in this fallback chain
          # at the end. An INNER JOIN used to drop them, which hid products.
          # MySQL has no NULLS LAST clause; NULL already sorts first there.
          nulls = connection.adapter_name.to_s.downcase.include?("mysql") ? "" : " NULLS LAST"
          Arel.sql("#{fallback_value_sql(column)} #{dir}#{nulls}")
        else
          arel_table[column.to_s].public_send(dir == "DESC" ? :desc : :asc)
        end
      end

      def normalize_order_direction(direction)
        direction.to_s.casecmp("desc").zero? ? "DESC" : "ASC"
      end

      def parse_translated_order(opts)
        case opts
        when Hash
          return nil unless opts.any? { |column, _direction| translated_column?(column) }

          opts.map { |column, direction| order_node_for(column, direction) }
        when Symbol
          return nil unless translated_column?(opts)

          [order_node_for(opts, :asc)]
        when String
          # `order("title ASC")` is raw SQL and would hit the parent table, where
          # the column often no longer exists. Rewrite only a bare column name.
          match = opts.match(/\A\s*([A-Za-z_][A-Za-z0-9_]*)(?:\s+(ASC|DESC))?\s*\z/i)
          return nil unless match && translated_column?(match[1])

          [order_node_for(match[1], match[2] || :asc)]
        when Array
          return nil unless opts.any? { |column| translated_column?(column) }

          opts.map { |column| order_node_for(column, :asc) }
        else
          nil
        end
      end

      def parse_translated_columns(columns)
        return unless columns.is_a?(Array)

        flat = columns.flatten
        return unless flat.any? { |column| translated_column?(column) }

        flat.map { |column| translated_column?(column) ? translated_column_name(column) : column }
      end

      def translated_column?(column)
        return false unless column.is_a?(Symbol) || column.is_a?(String)

        translated_attribute_names.include?(column.to_sym)
      end

      def unsupported_predicate_value?(value)
        value.is_a?(Range) || value.is_a?(Hash) || value.is_a?(Arel::Nodes::Node) ||
          (defined?(::ActiveRecord::Relation) && value.is_a?(::ActiveRecord::Relation))
      end

      def scalar_primary_key
        key = primary_key
        key.is_a?(Array) ? key.first : key
      end
    end
  end
end
