module Globalize
  module Validations
    module UniquenessValidator
      def validate_each(record, attribute, value)
        klass = record.class
        unless klass.respond_to?(:translates?) && klass.translates? && klass.translated?(attribute)
          return super
        end

        finder_class = klass.translation_class
        value = map_enum_attribute(finder_class, attribute, value)
        return if skip_translated_uniqueness_query?(finder_class, record, attribute)

        relation = build_relation(finder_class, attribute, value).where(locale: Globalize.locale.to_s)
        if record.persisted?
          foreign_key = klass.reflect_on_association(:translations).foreign_key
          relation = relation.where.not(foreign_key => record.id_in_database)
        end

        relation = apply_uniqueness_scopes(record, klass, relation)
        relation = apply_uniqueness_conditions(relation, record)

        return unless relation.exists?

        error_options = options.except(:case_sensitive, :scope, :conditions)
        error_options[:value] = value
        record.errors.add(attribute, :taken, **error_options)
      end

      private

      # A unique index on (attribute, locale) already proves uniqueness for the
      # current locale. Skip the SELECT when the value did not change.
      def skip_translated_uniqueness_query?(finder_class, record, attribute)
        return false unless record.persisted?
        return false if options[:conditions] || options.key?(:case_sensitive)

        names = Array(options[:scope]).map(&:to_s) + [attribute.to_s]
        return false if names.any? { |name| record.attribute_changed?(name) || record.read_attribute(name).nil? }

        covered = names + ["locale"]
        finder_class.schema_cache.indexes(finder_class.table_name).any? do |index|
          index.unique && index.where.nil? && (Array(index.columns).map(&:to_s) - covered).empty?
        end
      rescue StandardError
        false
      end

      def apply_uniqueness_scopes(record, klass, relation)
        scope_names = Array(options[:scope]).map { |item| item.respond_to?(:to_sym) ? item.to_sym : item }
        translated_scopes = scope_names & klass.translated_attribute_names
        untranslated_scopes = scope_names - translated_scopes

        if untranslated_scopes.present?
          relation = relation.joins(:globalized_model)
          untranslated_scopes.each do |scope_item|
            scope_value = record.public_send(scope_item)
            reflection = klass.reflect_on_association(scope_item)
            if reflection
              scope_value = record.public_send(reflection.foreign_key)
              scope_item = reflection.foreign_key
            end
            relation = relation.where(klass.table_name => { scope_item => scope_value })
          end
        end

        translated_scopes.each do |scope_item|
          relation = relation.where(scope_item => record.public_send(scope_item))
        end

        relation
      end

      # Rails 5+ passes :conditions as a callable. Relation#merge does not run it.
      def apply_uniqueness_conditions(relation, record)
        conditions = options[:conditions]
        return relation unless conditions

        if conditions.respond_to?(:call)
          if conditions.arity.zero?
            relation.instance_exec(&conditions)
          else
            relation.instance_exec(record, &conditions)
          end
        else
          relation.merge(conditions)
        end
      end
    end
  end
end

ActiveRecord::Validations::UniquenessValidator.prepend Globalize::Validations::UniquenessValidator
