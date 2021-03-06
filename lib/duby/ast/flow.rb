module Duby
  module AST
    class Condition < Node
      child :predicate

      def initialize(parent, line_number, &block)
        super(parent, line_number, &block)
      end

      def infer(typer)
        unless resolved?
          @inferred_type = typer.infer(predicate)
          if @inferred_type && !@inferred_type.primitive?
            call = Call.new(parent, position, '!=') do |call|
              predicate.parent = call
              [predicate, [Null.new(call, position)]]
            end
            self.predicate = call
            @inferred_type = typer.infer(predicate)
          end

          @inferred_type ? resolved! : typer.defer(self)
        end

        @inferred_type
      end
    end

    class If < Node
      child :condition
      child :body
      child :else

      def initialize(parent, line_number, &block)
        super(parent, line_number, &block)
      end

      def infer(typer)
        unless resolved?
          condition_type = typer.infer(condition)
          unless condition_type
            typer.defer(condition)
          end

          # condition type is unrelated to body types, so we proceed with bodies
          then_type = typer.infer(body) if body

          if !then_type
            # attempt to determine else branch
            if self.else
              else_type = typer.infer(self.else)

              if !else_type
                # we have neither type, defer until later
                typer.defer(self)
              else
                # we have else but not then, defer only then and use else type for now
                @inferred_type = else_type
                if body
                  typer.defer(self)
                else
                  resolved! if condition_type
                end
              end
            else
              # no then type could be inferred and no else body, defer for now
              typer.defer(self)
            end
          else
            if self.else
              else_type = typer.infer(self.else)

              if !else_type
                # we determined a then type, so we use that and defer the else body
                @inferred_type = then_type
                typer.defer(self)
              else
                # both then and else inferred, ensure they're compatible
                if then_type.compatible?(else_type)
                  # types are compatible...if condition is resolved, we're done
                  @inferred_type = then_type.narrow(else_type)
                  resolved! if condition_type
                else
                  raise Typer::InferenceError.new("if statement with incompatible result types")
                end
              end
            else
              # only then and type inferred, we're 100% resolved
              @inferred_type = then_type
              resolved! if condition_type
            end
          end
        end

        @inferred_type
      end
    end

    class Loop < Node
      child :init
      child :condition
      child :pre
      child :body
      child :post
      attr_accessor :check_first, :negative, :redo

      def initialize(parent, position, check_first, negative, &block)
        @check_first = check_first
        @negative = negative

        @children = [
            Body.new(self, position),
            nil,
            Body.new(self, position),
            nil,
            Body.new(self, position),
        ]
        super(parent, position) do |l|
          condition, body = yield(l)
          [self.init, condition, self.pre, body, self.post]
        end
      end

      def infer(typer)
        unless resolved?
          child_types = children.map do |c|
            if c.nil? || (Body === c && c.empty?)
              typer.no_type
            else
              typer.infer(c)
            end
          end
          if child_types.any? {|t| t.nil?}
            typer.defer(self)
          else
            resolved!
            @inferred_type = typer.null_type
          end
        end

        @inferred_type
      end

      def check_first?; @check_first; end
      def negative?; @negative; end

      def redo?
        if @redo.nil?
          nodes = @children.dup
          until nodes.empty?
            node = nodes.shift
            while node.respond_to?(:inlined) && node.inlined
              node = node.inlined
            end
            next if node.nil? || Loop === node
            if Redo === node
              return @redo = true
            end
            nodes.insert(-1, *node.children.flatten)
          end
          return @redo = false
        else
          @redo
        end
      end

      def init?
        init && !(init.kind_of?(Body) && init.empty?)
      end

      def pre?
        pre && !(pre.kind_of?(Body) && pre.empty?)
      end

      def post?
        post && !(post.kind_of?(Body) && post.empty?)
      end

      def to_s
        "Loop(check_first = #{check_first?}, negative = #{negative?})"
      end
    end

    class Not < Node
      def initialize(parent, line_number, &block)
        super(parent, line_number, &block)
      end
    end

    class Return < Node
      include Valued

      child :value

      def initialize(parent, line_number, &block)
        super(parent, line_number, &block)
      end

      def infer(typer)
        unless resolved?
          @inferred_type = typer.infer(value)

          (@inferred_type && value.resolved?) ? resolved! : typer.defer(self)
        end

        @inferred_type
      end
    end

    class Break < Node;
      def infer(typer)
        unless resolved?
          resolved!
          @inferred_type = typer.null_type
        end
        @inferred_type
      end
    end

    class Next < Break; end

    class Redo < Break; end

    class Raise < Node
      include Valued

      child :exception

      def initialize(parent, line_number, &block)
        super(parent, line_number, &block)
      end

      def infer(typer)
        unless resolved?
          @inferred_type = AST.unreachable_type
          throwable = AST.type('java.lang.Throwable')
          if children.size == 1
            arg_type = typer.infer(self.exception)
            unless arg_type
              typer.defer(self)
              return
            end
            if throwable.assignable_from?(arg_type) && !arg_type.meta?
              resolved!
              return @inferred_type
            end
          end

          arg_types = children.map {|c| typer.infer(c)}
          if arg_types.any? {|c| c.nil?}
            typer.defer(self)
          else
            if arg_types[0] && throwable.assignable_from?(arg_types[0])
              klass = children.shift
            else
              klass = Constant.new(self, position, 'RuntimeException')
            end
            exception = Call.new(self, position, 'new') do
              [klass, children, nil]
            end
            resolved!
            @children = [exception]
            typer.infer(exception)
          end
        end
        @inferred_type
      end
    end

    defmacro('raise') do |transformer, fcall, parent|
      Raise.new(parent, fcall.position) do |raise_node|
        if fcall.args_node
          fcall.args_node.child_nodes.map do |arg|
            transformer.transform(arg, raise_node)
          end
        end
      end
    end

    class RescueClause < Node
      include Scoped
      attr_accessor :name, :type
      child :types
      child :body

      def initialize(parent, position, &block)
        super(parent, position, &block)
      end

      def infer(typer)
        unless resolved?
          if name
            scope.static_scope << name
            orig_type = typer.local_type(containing_scope, name)
            # TODO find the common parent Throwable
            @type = types.size == 1 ? types[0] : AST.type('java.lang.Throwable')
            typer.learn_local_type(containing_scope, name, @type)
          end
          @inferred_type = typer.infer(body)

          if (@inferred_type && !body.resolved?)
            puts "#{body} not resolved"
          end

          (@inferred_type && body.resolved?) ? resolved! : typer.defer(self)
          typer.local_type_hash(containing_scope)[name] = orig_type if name
        end

        @inferred_type
      end
    end

    class Rescue < Node
      child :body
      child :clauses
      def initialize(parent, position, &block)
        super(parent, position, &block)
        @body, @clauses = children
      end

      def infer(typer)
        unless resolved?
          types = [typer.infer(body)] + clauses.map {|c| typer.infer(c)}
          if types.any? {|t| t.nil?}
            typer.defer(self)
          else
            # TODO check types for compatibility (maybe only if an expression)
            resolved!
            @inferred_type = types[0]
          end
        end
        @inferred_type
      end
    end

    class Ensure < Node
      child :body
      child :clause
      attr_accessor :state  # Used by the some compilers.

      def initialize(parent, position, &block)
        super(parent, position, &block)
      end

      def infer(typer)
        resolve_if(typer) do
          typer.infer(clause)
          typer.infer(body)
        end
      end
    end
  end
end