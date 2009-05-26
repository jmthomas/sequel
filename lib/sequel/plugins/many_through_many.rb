module Sequel
  module Plugins
    # The many_through_many plugin allow you to create a association to multiple objects using multiple join tables.
    # For example, assume the following associations:
    #
    #    Artist.many_to_many :albums
    #    Album.many_to_many :tags
    #
    # The many_through_many plugin would allow this:
    #
    #    Artist.many_through_many :tags, [[:albums_artists, :artist_id, :album_id], [:albums, :id, :id], [:albums_tags, :album_id, :tag_id]]
    #
    # Which will give you the tags for all of the artist's albums.
    #
    # Here are some more examples:
    #
    #   # Same as Artist.many_to_many :albums
    #   Artist.many_through_many :albums, [[:albums_artists, :artist_id, :album_id]]
    #
    #   # All artists that are associated to any album that this artist is associated to
    #   Artist.many_through_many :artists, [[:albums_artists, :artist_id, :album_id], [:albums, :id, :id], [:albums_artists, :album_id, :artist_id]]
    #
    #   # All albums by artists that are associated to any album that this artist is associated to
    #   Artist.many_through_many :artist_albums, [[:albums_artists, :artist_id, :album_id], [:albums, :id, :id], \
    #    [:albums_artists, :album_id, :artist_id], [:artists, :id, :id], [:albums_artists, :artist_id, :album_id]], \
    #    :class=>:Album
    #
    #   # All tracks on albums by this artist
    #   Artist.many_through_many :tracks, [[:albums_artists, :artist_id, :album_id], [:albums, :id, :id]], \
    #    :right_primary_key=>:album_id
    module ManyThroughMany
      # The AssociationReflection subclass for many_through_many associations.
      class ManyThroughManyAssociationReflection < Sequel::Model::Associations::ManyToManyAssociationReflection
        Sequel::Model::Associations::ASSOCIATION_TYPES[:many_through_many] = self

        # The table containing the column to use for the associated key when eagerly loading
        def associated_key_table
          self[:associated_key_table] = self[:final_reverse_edge][:alias]
        end

        # The list of joins to use when eager graphing
        def edges
          self[:edges] || calculate_edges || self[:edges]
        end

        # Many through many associations don't have a reciprocal
        def reciprocal
          nil
        end

        # The list of joins to use when lazy loading or eager loading
        def reverse_edges
          self[:reverse_edges] || calculate_edges || self[:reverse_edges]
        end

        private

        # Make sure to use unique table aliases when lazy loading or eager loading
        def calculate_reverse_edge_aliases(reverse_edges)
          aliases = [associated_class.table_name]
          reverse_edges.each do |e|
            table_alias = e[:table]
            if aliases.include?(table_alias)
              i = 0
              table_alias = loop do
                ta = :"#{table_alias}_#{i}"
                break ta unless aliases.include?(ta)
                i += 1
              end
            end
            aliases.push(e[:alias] = table_alias)
          end
        end

        # Transform the :through option into a list of edges and reverse edges to use to join tables when loading the association.
        def calculate_edges
          es = [{:left_table=>self[:model].table_name, :left_key=>self[:left_primary_key]}]
          self[:through].each do |t|
            es.last.merge!(:right_key=>t[:left], :right_table=>t[:table], :join_type=>t[:join_type]||self[:graph_join_type], :conditions=>(t[:conditions]||[]).to_a, :block=>t[:block])
            es.last[:only_conditions] = t[:only_conditions] if t.include?(:only_conditions)
            es << {:left_table=>t[:table], :left_key=>t[:right]}
          end
          es.last.merge!(:right_key=>right_primary_key, :right_table=>associated_class.table_name)
          edges = es.map do |e| 
            h = {:table=>e[:right_table], :left=>e[:left_key], :right=>e[:right_key], :conditions=>e[:conditions], :join_type=>e[:join_type], :block=>e[:block]}
            h[:only_conditions] = e[:only_conditions] if e.include?(:only_conditions)
            h
          end
          reverse_edges = es.reverse.map{|e| {:table=>e[:left_table], :left=>e[:left_key], :right=>e[:right_key]}}
          reverse_edges.pop
          calculate_reverse_edge_aliases(reverse_edges)
          self[:final_edge] = edges.pop
          self[:final_reverse_edge] = reverse_edges.pop
          self[:edges] = edges
          self[:reverse_edges] = reverse_edges
          nil
        end
      end
      module ClassMethods
        # Create a many_through_many association.  Arguments:
        # * name - Same as associate, the name of the association.
        # * through - The tables and keys to join between the current table and the associated table.
        #   Must be an array, with elements that are either 3 element arrays, or hashes with keys :table, :left, and :right.
        #   The required entries in the array/hash are:
        #   * :table (first array element) - The name of the table to join.
        #   * :left (middle array element) - The key joining the table to the previous table
        #   * :right (last array element) - The key joining the table to the next table
        #   If a hash is provided, the following keys are respected when using eager_graph:
        #   * :block - A proc to use as the block argument to join.
        #   * :conditions - Extra conditions to add to the JOIN ON clause.  Must be a hash or array of two pairs.
        #   * :join_type - The join type to use for the join, defaults to :left_outer.
        #   * :only_conditions - Conditions to use for the join instead of the ones specified by the keys.
        # * opts - The options for the associaion.  Takes the same options as associate, and supports these additional options:
        #   * :left_primary_key - column in current table that the first :left option in through points to, as a symbol. Defaults to primary key of current table. 
        #   * :right_primary_key - column in associated table that the final :right option in through points to, as a symbol. Defaults to primary key of the associated table.
        #   * :uniq - Adds a after_load callback that makes the array of objects unique.
        def many_through_many(name, through, opts={}, &block)
          associate(:many_through_many, name, opts.merge(:through=>through), &block)
        end 

        private

        # Create the association methods and :eager_loader and :eager_grapher procs.
        def def_many_through_many(opts)
          name = opts[:name]
          model = self
          opts[:read_only] = true
          opts[:class_name] ||= camelize(singularize(name))
          opts[:after_load].unshift(:array_uniq!) if opts[:uniq]
          opts[:cartesian_product_number] ||= 2
          opts[:through] = opts[:through].map do |e|
            case e
            when Array
              raise(Error, "array elements of the through option/argument for many_through_many associations must have at least three elements") unless e.length == 3
              {:table=>e[0], :left=>e[1], :right=>e[2]}
            when Hash
              raise(Error, "hash elements of the through option/argument for many_through_many associations must contain :table, :left, and :right keys") unless e[:table] && e[:left] && e[:right]
              e
            else
              raise(Error, "the through option/argument for many_through_many associations must be an enumerable of arrays or hashes")
            end
          end

          left_key = opts[:left_key] = opts[:through].first[:left]
          left_pk = (opts[:left_primary_key] ||= self.primary_key)
          opts[:dataset] ||= lambda do
            ds = opts.associated_class
            opts.reverse_edges.each{|t| ds = ds.join(t[:table], [[t[:left], t[:right]]], :table_alias=>t[:alias])}
            ft = opts[:final_reverse_edge]
            ds.join(ft[:table], [[ft[:left], ft[:right]], [left_key, send(left_pk)]], :table_alias=>ft[:alias])
          end

          left_key_alias = opts[:left_key_alias] ||= opts.default_associated_key_alias
          opts[:eager_loader] ||= lambda do |key_hash, records, associations|
            h = key_hash[left_pk]
            records.each{|object| object.associations[name] = []}
            ds = opts.associated_class 
            opts.reverse_edges.each{|t| ds = ds.join(t[:table], [[t[:left], t[:right]]], :table_alias=>t[:alias])}
            ft = opts[:final_reverse_edge]
            ds = ds.join(ft[:table], [[ft[:left], ft[:right]], [left_key, h.keys]], :table_alias=>ft[:alias])
            model.eager_loading_dataset(opts, ds, Array(opts.select), associations).all do |assoc_record|
              next unless objects = h[assoc_record.values.delete(left_key_alias)]
              objects.each{|object| object.associations[name].push(assoc_record)}
            end
          end

          join_type = opts[:graph_join_type]
          select = opts[:graph_select]
          graph_block = opts[:graph_block]
          only_conditions = opts[:graph_only_conditions]
          use_only_conditions = opts.include?(:graph_only_conditions)
          conditions = opts[:graph_conditions]
          opts[:eager_grapher] ||= proc do |ds, assoc_alias, table_alias|
            iq = table_alias
            opts.edges.each do |t|
              ds = ds.graph(t[:table], t.include?(:only_conditions) ? t[:only_conditions] : ([[t[:right], t[:left]]] + t[:conditions]), :select=>false, :table_alias=>ds.send(:eager_unique_table_alias, ds, t[:table]), :join_type=>t[:join_type], :implicit_qualifier=>iq, &t[:block])
              iq = nil
            end
            fe = opts[:final_edge]
            ds.graph(opts.associated_class, use_only_conditions ? only_conditions : ([[opts.right_primary_key, fe[:left]]] + conditions), :select=>select, :table_alias=>assoc_alias, :join_type=>join_type, &graph_block)
          end

          def_association_dataset_methods(opts)
        end
      end
    end
  end
end
