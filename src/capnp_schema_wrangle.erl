-module(capnp_schema_wrangle).

-include_lib("capnp.hrl").
-include_lib("capnp_schema.hrl").

-export([
		node_name/2,
		field_info/2,

		schema_lookup/2,
		find_record_fields/2,
		find_fields/2,
		find_notag_fields/2,
		find_notag_groups/2,
		find_notag_data_fields/2,
		find_notag_pointer_fields/2,
		find_tag_fields/2,
		find_anon_union/2,
		flatten_notag_fields/2,
		discriminant_field/2,
		is_union/2,
		is_union_type/1,
		is_group/2,

		is_native_type/1,
		is_nonvoid_native_type/1,
		is_pointer_type/1,
		is_group_type/1
	]).

-import(capnp_common, [
		to_atom/1
	]).

node_name({anonunion, TypeId}, Schema) ->
	{Name, DWords, PWords} = node_name(TypeId, Schema),
	{<<Name/binary, $.>>, DWords, PWords};
node_name(TypeId, Schema) ->
	#'Node'{
		displayName=Name,
		''={
			struct,
			#'Node_struct'{
				dataWordCount=DWords,
				pointerCount=PWords
			}
		}
	} = schema_lookup(TypeId, Schema),
	{Name, DWords, PWords}.

is_union(TypeId, Schema) ->
	find_notag_fields(TypeId, Schema) == [] andalso find_tag_fields(TypeId, Schema) /= [].

is_union_type(Schema) ->
	fun
		(#field_info{type=#group_type{type_id=TypeId}}) ->
			is_union(TypeId, Schema);
		(_) ->
			false
	end.

is_group(TypeId, Schema) ->
	#'Node'{
		''={
			struct,
			#'Node_struct'{
				isGroup=IsGroup
			}
		}
	} = schema_lookup(TypeId, Schema),
	IsGroup.

has_discriminant(#field_info{discriminant=undefined}) -> false;
has_discriminant(#field_info{}) -> true.

has_no_discriminant(F) -> not has_discriminant(F).

find_record_fields(TypeId, Schema) ->
	find_notag_data_fields(TypeId, Schema) ++ find_notag_pointer_fields(TypeId, Schema) ++ find_anon_union(TypeId, Schema) ++ find_notag_groups(TypeId, Schema).

is_native_type(#field_info{type=#native_type{}}) -> true;
is_native_type(#field_info{}) -> false.

is_nonvoid_native_type(#field_info{type=#native_type{width=0}}) -> false;
is_nonvoid_native_type(Field) -> is_native_type(Field).

is_pointer_type(#field_info{type=#ptr_type{}}) -> true;
is_pointer_type(#field_info{}) -> false.

is_group_type(#field_info{type=#group_type{}}) -> true;
is_group_type(#field_info{}) -> false.

find_notag_data_fields(TypeId, Schema) ->
	lists:sort(lists:filter(fun is_native_type/1, find_notag_fields(TypeId, Schema))).

find_notag_pointer_fields(TypeId, Schema) ->
	lists:sort(lists:filter(fun is_pointer_type/1, find_notag_fields(TypeId, Schema))).

find_notag_groups(TypeId, Schema) ->
	% TODO SORT!!!
	lists:filter(fun is_group_type/1, find_notag_fields(TypeId, Schema)).

flatten_notag_fields(GroupTypeId, Schema) ->
	lists:sort(flatten_notag_fields(GroupTypeId, <<"">>, Schema)).

flatten_notag_fields(TypeId, Prefix, Schema) ->
	{Groups, Rest} = lists:partition(fun is_group_type/1, find_notag_fields(TypeId, Schema)),
	RecursiveFields =
		[flatten_notag_fields(GroupTypeId, <<Prefix/binary, TypeName/binary>>, Schema)
			|| #field_info{type=#group_type{type_id=GroupTypeId}, name=TypeName} <- Groups,
			not is_union(GroupTypeId, Schema)],
	DirectFields =
		[Info#field_info{name= <<Prefix/binary, TypeName/binary>>}
			|| Info=#field_info{name=TypeName} <- Rest],
	lists:append([DirectFields|RecursiveFields]).

find_notag_fields({anonunion, _TypeId}, _Schema) ->
	[];
find_notag_fields(TypeId, Schema) ->
	lists:filter(fun has_no_discriminant/1, find_fields(TypeId, Schema)).

find_tag_fields(TypeId, Schema) ->
	lists:filter(fun has_discriminant/1, find_fields(TypeId, Schema)).

find_anon_union(TypeId, Schema) ->
	#'Node'{
		''={
			struct,
			#'Node_struct'{
				discriminantCount=DiscriminantCount
			}
		}
	} = schema_lookup(TypeId, Schema),
	case DiscriminantCount of
		0 ->
			[];
		X when X > 0 ->
			[ #field_info{name= <<>>, type=#group_type{type_id={anonunion, TypeId}}} ]
	end.

find_fields(TypeId, Schema) ->
	#'Node'{
		''={
			struct,
			#'Node_struct'{
				fields=Fields
			}
		}
	} = schema_lookup(TypeId, Schema),
	% Start by finding the bit offsets of each field, so that we can order them.
	[ field_info(Field, Schema) || Field <- Fields ].

schema_lookup({anonunion, TypeId}, Schema) ->
	schema_lookup(TypeId, Schema);
schema_lookup(Name, Schema) when is_binary(Name) ->
	TypeId = dict:fetch(Name, Schema#capnp_context.name_to_id),
	schema_lookup(TypeId, Schema);
schema_lookup(TypeId, Schema) when is_integer(TypeId) ->
	dict:fetch(TypeId, Schema#capnp_context.by_id).

field_info(#'Field'{
		discriminantValue=DiscriminantValue,
		name=Name,
		''={
			slot,
			#'Field_slot'{
				offset=N,
				defaultValue={TypeClass, DefaultValue},
				type=Type={TypeClass, _TypeDescription}
			}
		}
	}, Schema) ->
	{Size, Info} = type_info(Type, Schema),
	Offset = case Size of
		1 ->
			% Correct for erlang's endianness
			(N band -8) + (7 - (N band 7));
		_ ->
			Size * N
	end,
	#field_info{offset=Offset, type=Info, name=Name, discriminant=if DiscriminantValue =:= 65535 -> undefined; true -> DiscriminantValue end, default=case DefaultValue of not_implemented -> undefined; _ -> DefaultValue end};
field_info(#'Field'{
		discriminantValue=DiscriminantValue,
		name=Name,
		''={
			group,
			TypeId
		}
	}, Schema) ->
	Fields = find_fields(TypeId, Schema),
	% If there are no fields, destroy this group.
	% If there's just one field, replace this group with it.
	% If there's multiple fields, generate a group_type field.
	case Fields of
		[] ->
			#field_info{offset=undefined, type=deleted};
		[Field=#field_info{}] ->
			Field#field_info{name=Name, discriminant=if DiscriminantValue =:= 65535 -> undefined; true -> DiscriminantValue end};
		_ ->
			% Groups and unions.
			#field_info{offset=undefined, type=#group_type{type_id=TypeId}, name=Name, discriminant=if DiscriminantValue =:= 65535 -> undefined; true -> DiscriminantValue end}
	end.

type_info({TypeClass, TypeDescription}, Schema) ->
	type_info(TypeClass, TypeDescription, Schema).

% Pointer types (composite/list)
type_info(TextType, undefined, _Schema) when TextType =:= text; TextType =:= data ->
	{64, #ptr_type{type=text_or_data, extra=TextType}};
type_info(anyPointer, {unconstrained, undefined}, _Schema) ->
	{64, #ptr_type{type=unknown}}; % Not really possible
type_info(struct, #'Type_struct'{typeId=TypeId}, Schema) when is_integer(TypeId) ->
	{TypeName, DataLen, PtrLen} = node_name(TypeId, Schema),
	{64, #ptr_type{type=struct, extra={TypeName, DataLen, PtrLen}}};
type_info(list, {enum, #'Type_enum'{typeId=TypeId}}, Schema) ->
	% List of enums.
	EnumerantNames = enumerant_names(TypeId, Schema),
	{64, #ptr_type{type=list, extra={primitive, #native_type{type=enum, extra=EnumerantNames, width=16, binary_options=[little,unsigned,integer], list_tag=3}}}};
type_info(list, {TextType, undefined}, _Schema) when TextType =:= text; TextType =:= data ->
	% List of text types; this is a list-of-lists.
	{64, #ptr_type{type=list, extra={text, TextType}}};
type_info(list, {list, {TextType, undefined}}, _Schema) when TextType =:= text; TextType =:= data ->
	% List of text types; this is a list-of-lists.
	{64, #ptr_type{type=list, extra={list, {text, TextType}}}};
type_info(list, {PtrType, LTypeDescription}, _Schema) when PtrType =:= list ->
	% List of list, or list-of-(text or data) -- all three are lists of lists of lists.
	erlang:error({not_implemented, list, list, LTypeDescription}); % TODO
type_info(list, {PrimitiveType, undefined}, _Schema) ->
	% List of any normal primitive type.
	{64, #ptr_type{type=list, extra={primitive, builtin_info(PrimitiveType)}}};
type_info(list, InnerType={struct, _}, Schema) ->
	% List of structs.
	% These will be encoded in-line.
	{64, TypeInfo} = type_info(InnerType, Schema),
	{64, #ptr_type{type=list, extra={struct, TypeInfo}}};
type_info(list, {anyPointer, undefined}, _Schema) ->
	erlang:error({not_implemented, list, anyPointer}); % TODO
type_info(list, {interface,_LTypeId}, _Schema) ->
	erlang:error({not_implemented, list, interface}); % TODO
% TODO decoders for pointers.
% Data types
type_info(enum, #'Type_enum'{typeId=TypeId}, Schema) when is_integer(TypeId) ->
	EnumerantNames = enumerant_names(TypeId, Schema),
	{16, #native_type{type=enum, extra=EnumerantNames, width=16, binary_options=[little,unsigned,integer], list_tag=3}};
type_info(TypeClass, undefined, _Schema) ->
	Info1 = #native_type{width=Size1} = builtin_info(TypeClass),
	{Size1, Info1};
% Catchall
type_info(TypeClass, TypeDescription, _Schema) ->
	io:format("Unknown: ~p~n", [{TypeClass, TypeDescription}]),
	{64, #ptr_type{type=unknown}}.


enumerant_names(TypeId, Schema) ->
	#'Node'{
		''={
			enum,
			Enumerants
		}
	} = schema_lookup(TypeId, Schema),
	[ to_atom(EName) || #'Enumerant'{name=EName} <- Enumerants ].

discriminant_field(TypeId, Schema) ->
	#'Node'{
		''={
			struct,
			#'Node_struct'{
				discriminantOffset=DiscriminantOffset
			}
		}
	} = schema_lookup(TypeId, Schema),
	#field_info{name= <<"Discriminant">>, offset=DiscriminantOffset*16, type=builtin_info(uint16), default=0}.

% {BroadType, Bits, BinaryType}
builtin_info(int64) -> #native_type{name=int64, type=integer, width=64, binary_options=[little, signed, integer], list_tag=5};
builtin_info(int32) -> #native_type{name=int32, type=integer, width=32, binary_options=[little, signed, integer], list_tag=4};
builtin_info(int16) -> #native_type{name=int16, type=integer, width=16, binary_options=[little, signed, integer], list_tag=3};
builtin_info(int8) -> #native_type{name=int8, type=integer, width=8, binary_options=[little, signed, integer], list_tag=2};
builtin_info(uint64) -> #native_type{name=uint64, type=integer, width=64, binary_options=[little, unsigned, integer], list_tag=5};
builtin_info(uint32) -> #native_type{name=uint32, type=integer, width=32, binary_options=[little, unsigned, integer], list_tag=4};
builtin_info(uint16) -> #native_type{name=uint16, type=integer, width=16, binary_options=[little, unsigned, integer], list_tag=3};
builtin_info(uint8) -> #native_type{name=uint8, type=integer, width=8, binary_options=[little, unsigned, integer], list_tag=2};
builtin_info(float32) -> #native_type{name=float32, type=float, width=32, binary_options=[little, float], list_tag=4};
builtin_info(float64) -> #native_type{name=float64, type=float, width=64, binary_options=[little, float], list_tag=5};
builtin_info(bool) -> #native_type{name=bool, type=boolean, width=1, binary_options=[integer], list_tag=1};
builtin_info(void) -> #native_type{name=void, type=void, width=0, binary_options=[integer], list_tag=0}.
