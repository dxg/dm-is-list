module DataMapper
  module Is
    module List

      ##
      # method for making your model a list.
      # it will define a :position property if it does not exist, so be sure to have a
      # position-column in your database (will be added automatically on auto_migrate)
      # if the column has a different name, simply make a :position-property and set a
      # custom :field
      #
      # @example [Usage]
      #   is :list  # put this in your model to make it act as a list.
      #   is :list, :scope => [:user_id] # you can also define scopes
      #   is :list, :scope => [:user_id, :context_id] # also works with multiple params
      #
      # @param options <Hash> a hash of options
      #
      # @option :scope<Array> an array of attributes that should be used to scope lists
      #
      def is_list(options={})
        options = { :scope => [], :first => 1 }.merge(options)

        extend  DataMapper::Is::List::ClassMethods
        include DataMapper::Is::List::InstanceMethods

        unless properties.any? { |p| p.name == :position && p.type == Integer }
          property :position, Integer
        end

        @list_options = options

        before :create do
          # a position has been set before save => open up and make room for item
          # no position has been set => move to bottom of my scope-list (or keep detached?)
          send(:move_without_saving, position || :lowest)
        end

        before :update do
          # if the scope has changed, we need to detach our item from the old list
          if list_scope != original_list_scope
            newpos = position
            detach(original_list_scope) # removing from old list
            send(:move_without_saving, newpos || :lowest) # moving to pos or bottom of new list
          elsif attribute_dirty?(:position) && !moved
            send(:move_without_saving, position)
          end

          # on update, clean moved to prepare for the next change
          self.moved = false

          # a (new) position has been set => move item to this position (only if position has been set manually)
          # the scope has changed => detach from old list, and possibly move into position
          # the scope and position has changed => detach from old, move to pos in new
        end

        before :destroy do
          detach
        end

        # we need to make sure that STI-models will inherit the list_scope.
        after_class_method :inherited do |retval, target|
          target.instance_variable_set(:@list_options, @list_options.dup)
        end
      end

      module ClassMethods
        attr_reader :list_options

        ##
        # use this function to repair / build your lists.
        #
        # @example [Usage]
        #   MyModel.repair_list # repairs the list, given that lists are not scoped
        #   MyModel.repair_list(:user_id => 1) # fixes the list for user 1, given that the scope is [:user_id]
        #
        # @param scope [Hash]
        #
        def repair_list(scope = {})
          return false unless scope.keys.all?{ |s| list_options[:scope].include?(s) || s == :order }
          all({ :order => [ :position ] }.merge(scope)).each_with_index{ |item, i| item.update(:position => i + 1) }
          true
        end
      end

      module InstanceMethods
        attr_accessor :moved

        def list_scope
          model.list_options[:scope].map{ |p| [ p, attribute_get(p) ] }.to_hash
        end

        def original_list_scope
          model.list_options[:scope].map{ |p| [ p, (property = properties[p]) && original_values.key?(property) ? original_values[property] : attribute_get(p) ] }.to_hash
        end

        def list_query
          list_scope.merge(:order => [ :position ])
        end

        def list(scope = list_query)
          model.all(scope)
        end

        ##
        # repair the list this item belongs to
        #
        def repair_list
          model.repair_list(list_scope)
        end

        ##
        # reorder the list this item belongs to
        #
        def reorder_list(order)
          model.repair_list(list_scope.merge(:order => order))
        end

        def detach(scope = list_scope)
          list(scope).all(:position.gt => position).adjust!({ :position => -1 },true)
          self.position = nil
        end

        def left_sibling
          list.reverse.first(:position.lt => position)
        end

        def right_sibling
          list.first(:position.gt => position)
        end

        ##
        # move item to a position in the list. position should _only_ be changed through this
        #
        # @example [Usage]
        #   * node.move :higher           # moves node higher unless it is at the top of parent
        #   * node.move :lower            # moves node lower unless it is at the bottom of parent
        #   * node.move :below => other   # moves this node below other resource in the set
        #
        # @param vector <Symbol, Hash> A symbol, or a key-value pair that describes the requested movement
        #
        # @option :higher<Symbol> move item higher
        # @option :up<Symbol> move item higher
        # @option :highest<Symbol> move item to the top of the list
        # @option :lower<Symbol> move item lower
        # @option :down<Symbol> move item lower
        # @option :lowest<Symbol> move item to the bottom of the list
        # @option :above<Resource> move item above other item. must be in same scope
        # @option :below<Resource> move item below other item. must be in same scope
        # @option :to<Fixnum> move item to a specific location in the list
        #
        # @return <TrueClass, FalseClass> returns false if it cannot move to the position, otherwise true
        # @see move_without_saving
        def move(vector)
          move_without_saving(vector) && save
        end

        ##
        # does all the actual movement in #move, but does not save afterwards. this is used internally in
        # before :save, and will probably be marked private. should not be used by organic beings.
        #
        # @see move
       private
        def move_without_saving(vector)
          if vector.kind_of?(Hash)
            action, object = vector.keys[0], vector.values[0]
          else
            action = vector
          end

          minpos = model.list_options[:first]
          prepos = original_values[properties[:position]] || position
          maxpos = (last = list.last) ? (last == self ? prepos : last.position + 1) : minpos

          newpos = case action
            when :highest     then minpos
            when :lowest      then maxpos
            when :higher,:up  then [ position - 1, minpos ].max
            when :lower,:down then [ position + 1, maxpos ].min
            when :above       then object.position
            when :below       then object.position + 1
            when :to          then [ minpos, [ object.to_i, maxpos ].min ].max
            else [ action.to_i, maxpos ].min
          end

          return false if [ :lower, :higher ].include?(action) && newpos == prepos
          return false if !newpos || ([ :above, :below ].include?(action) && list_scope != object.list_scope)
          return true  if newpos == position && position == prepos || (newpos == maxpos && position == maxpos - 1)

          if !position
            list.all(:position.gte => newpos).adjust!({ :position => 1 }, true) unless action == :lowest
          elsif newpos > prepos
            newpos -= 1 if [:lowest,:above,:below,:to].include?(action)
            list.all(:position => prepos..newpos).adjust!({ :position => -1 }, true)
          elsif newpos < prepos
            list.all(:position => newpos..prepos).adjust!({ :position => 1  }, true)
          end

          self.position = newpos
          self.moved = true
          true
        end
      end
    end # List
  end # Is
end # DataMapper
