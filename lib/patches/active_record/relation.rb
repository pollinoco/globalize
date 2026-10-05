module Globalize
  module Relation
    def where_values_hash(relation_table_name = table_name)
      return super unless respond_to?(:translations_table_name)
      super.merge(super(translations_table_name))
    end

    def scope_for_create
      scope = super
      if respond_to?(:translations_table_name)
        scope = scope.merge(where_values_hash(translations_table_name))
      end
      predicates = instance_variable_get(:@globalize_predicates)
      predicates.present? ? scope.merge(predicates.stringify_keys) : scope
    end
  end
end

ActiveRecord::Relation.prepend Globalize::Relation
