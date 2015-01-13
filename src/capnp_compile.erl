%% @author bucko
%% @doc @todo Add description to capnp_compile.


-module(capnp_compile).

-include_lib("capnp.hrl").
-include_lib("capnp_raw.hrl").
-include_lib("capnp_bootstrap.hrl").

-export([
		to_ast/2
	]).

-record(field_info, {a}).

% Compiled reader functions take as arguments a #deref_ptr{} and a #envelope{} for pointer lookups.
% Compiled writer functions take data as argument, and return an io_list() which is locally consistent.
to_ast(Name, Schema) ->
	TypeId = dict:fetch(Name, Schema#capnp_context.name_to_id),
	#'capnp::namespace::Node'{
		''={{1, struct},
			#'capnp::namespace::Node::::struct'{
				dataWordCount=DWords,
				pointerCount=PWords,
				fields=Fields
			}
		}
	} = dict:fetch(TypeId, Schema#capnp_context.by_id),
	% Start by finding the bit offsets of each field, so that we can order them.
	AllFields = lists:map(fun field_info/1, Fields),
	{PtrFields, DataFields} = lists:partition(fun ({_,ptr,_,_,_}) -> true end, AllFields),
	% We like these sorted.
	SortedDataFields = lists:sort(DataFields),
	SortedPtrFields = lists:sort(PtrFields),

	ok.

field_info(#'capnp::namespace::Field'{
		name=Name,
		''={{0,slot},
			#'capnp::namespace::Field::::slot'{
				offset=N,
				defaultValue=#'capnp::namespace::Value'{''={{_,TypeClass},DefaultValue}},
				type=#'capnp::namespace::Type'{''={{_,TypeClass},TypeDescription}}
			}
		}   
	}) ->
	{Offset, Size} = case {TypeClass, TypeDescription} of
		{text, void} ->
			{N, ptr};
		{data, void} ->
			{N, ptr};
		{anyPointer, void} ->
			{N, ptr};
		{_, void} ->
			{N, 1 bsl isize(TypeDescription)};
		_ ->
			{N, ptr}
	end,
	{Offset, Size, TypeClass, TypeDescription, Name, DefaultValue}.

% Convert a record into a segment, starting with the pointer to the binary.
to_bytes(Rec, Schema) ->
	Name = element(1, Rec),
	TypeId = dict:fetch(Name, Schema#capnp_context.name_to_id),
	{DWords, PWords, Raw, _RawSize, Extra, _FinalOffset} = to_bytes(Schema, TypeId, Rec, 0),
	list_to_binary([<<(struct_pointer(0, DWords, PWords)):?UInt64>>, Raw | Extra]).

% OffsetAfterHere is num words /after/ the pointer that the data segment starts. It will therefore often be zero.
struct_pointer(OffsetAfterHere, DWords, PWords) ->
	(OffsetAfterHere bsl 2) bor (DWords bsl 32) bor (PWords bsl 48).

% SizeTag is 0-index into bit sizes: {0, 1, 8, 16, 32, 64, 64(Pointer), 64-ish(Composite)}
% ElementCount is /word/ count in Composite case; we actually just special case this below.
plain_list_pointer(OffsetAfterHere, SizeTag, ElementCount) ->
	1 bor (OffsetAfterHere bsl 2) bor (SizeTag bsl 32) bor (ElementCount bsl 35).

% First elt is a pointer. Second is a list tag which looks a bit like a struct pointer; it should go on the start of the list elements.
composite_list_pointer(OffsetAfterHere, DWords, PWords, ElementCount) ->
	{
		1 bor (OffsetAfterHere bsl 2) bor (7 bsl 32) bor ((ElementCount*(DWords+PWords)) bsl 35),
		struct_pointer(ElementCount, DWords, PWords) % It's a bit ugly to call struct_pointer here, but it /does/ do the right thing.
	}.

% Convert a record into a byte stream. Each sub-structure will be placed immediately after this one in left-to-right order.
% Returns the data/pointer words in our structure, an unflattened io_list of the encoded structure and the total encoded length (in words).
to_bytes(Schema, TypeId, Obj) ->
	to_bytes(Schema, TypeId, Obj, 0).
to_bytes(Schema, TypeId, Obj, POffset) ->
	#'capnp::namespace::Node'{
		''={{1, struct},
			#'capnp::namespace::Node::::struct'{
				dataWordCount=DWords,
				pointerCount=PWords,
				fields=Fields
			}
		}
	} = dict:fetch(TypeId, Schema#capnp_context.by_id),
	{DataSeg, PointerSeg, ExtraData, ExtraDataLength} = encode_parts(Fields, tl(tuple_to_list(Obj)), list_to_tuple(lists:duplicate(DWords, 0)), list_to_tuple(lists:duplicate(PWords, 0)), POffset, [], Schema),
	Data = [flatten_seg(DataSeg)| flatten_seg(PointerSeg)],
	DataLength = DWords + PWords,
	{DWords, PWords, Data, DataLength, ExtraData, ExtraDataLength - POffset}.

encode_parts([
		#'capnp::namespace::Field'{
			''={{0,slot},
				#'capnp::namespace::Field::::slot'{
					offset=N,
					defaultValue=#'capnp::namespace::Value'{''={{_,TypeClass},DefaultValue}},
					type=#'capnp::namespace::Type'{''={{_,TypeClass},TypeDescription}}
				}
			}   
		}
		|RestFields], [Value|RestValues], DataSeg, PointerSeg, DataLength, Data, Schema) ->
	{NewDataSeg, NewPointerSeg, ExtraDataLength, ExtraData} = encode_field(TypeClass, TypeDescription, DefaultValue, N, Value, DataSeg, PointerSeg, DataLength, Schema),
	encode_parts(RestFields, RestValues, NewDataSeg, NewPointerSeg, DataLength + ExtraDataLength, [Data|ExtraData], Schema);
encode_parts(_, [], DataSeg, PointerSeg, ExtraDataLength, ExtraData, _Schema) ->
	% Offset is total data length of everything /extra/ we've put in.
	{DataSeg, PointerSeg, ExtraData, ExtraDataLength}.

% We actually don't need to care about the DefaultValue except for primitive fields.
% For composite fields, the default is either a null pointer, or a valid encoding of the entire structure as if it were set manually.
% We could save space here by potentially verifying that the default /is/ the default value, and encoding as a null pointer.
encode_field(TypeClass, TypeDescription, DefaultValue, N, Value, DataSeg, PointerSeg, ExtraDataLength, Schema) ->
	case {TypeClass, TypeDescription} of
		{anyPointer, void} ->
			erlang:error(not_implemented);
		{TextType, void} when TextType =:= text; TextType =:= data ->
			{Binary, ByteSize} = encode_text(TextType, Value),
			Pointer = plain_list_pointer(ExtraDataLength + (tuple_size(PointerSeg) - (N + 1)), 2, ByteSize),
			PadLength = -ByteSize band 7,
			Pad = << <<0:8>> || _ <- lists:seq(1, PadLength) >>,
			WordSize = (ByteSize + PadLength) bsr 3,
			NewPointerSeg = insert(N, PointerSeg, Pointer),
			{DataSeg, NewPointerSeg, WordSize, [Binary|Pad]};
		{_, void} ->
			{Shifts, Encoded} = encode(TypeClass, Value, DefaultValue, N),
			NewDataSeg = insert((N bsl (Shifts - 6)), DataSeg, Encoded),
			{NewDataSeg, PointerSeg, 0, []};
		{struct, #'capnp::namespace::Type::::struct'{typeId=TypeId}} when is_integer(TypeId)-> % TODO are these working fine in bootstrap_capnp? They're a :group.
			{DWords, PWords, Data, DataWords, NewExtraData, FinalOffset} = to_bytes(Schema, TypeId, Value, 0),
			% We're going to jam the new data on the end of the accumulator, so we must add the length of every structure we've added so far.
			% We also need to include the length of every pointer /after/ this one. Not that the first pointer is N=0.
			Pointer = struct_pointer(ExtraDataLength + (tuple_size(PointerSeg) - (N + 1)), DWords, PWords),
			NewPointerSeg = insert(N, PointerSeg, Pointer),
			{DataSeg, NewPointerSeg, DataWords + FinalOffset, [Data|NewExtraData]};
		{enum, #'capnp::namespace::Type::::enum'{typeId=TypeId}} when is_integer(TypeId) ->
			Index = encode_enum(TypeId, Value, Schema),
			{Shifts, Encoded} = encode(uint16, Index, DefaultValue, N),
			NewDataSeg = insert((N bsl (Shifts - 6)), DataSeg, Encoded),
			{NewDataSeg, PointerSeg, 0, []};			
		{list, #'capnp::namespace::Type::::list'{elementType=#'capnp::namespace::Type'{''={{_,PtrType},LTypeDescription}}}} when PtrType =:= list; PtrType =:= text; PtrType =:= data ->
			% Start the encode from the end of the list. Append the data, and prepend the pointers.
			% This means that the first pointer is always just a zero pointer.
			% The second must skip one list element, and all of the data that element caused.
			% Etc.
			FoldFun = fun (V, {I, Pointers, Data, DataLength}) ->
					{{}, {Pointer}, NewDataLength, NewData} = encode_field(PtrType, LTypeDescription, _Default=0, _N=0, V, _DataSeg={}, _PointerSeg={0}, DataLength+I, Schema),
					{I+1, [<<Pointer:?UInt64>>|Pointers], [Data|NewData], NewDataLength + DataLength}
			end,
			{ListLength, Pointers, Data, DataLength} = lists:foldr(FoldFun, {0, [], [], 0}, Value),
			Pointer = plain_list_pointer(ExtraDataLength + (tuple_size(PointerSeg) - (N + 1)), 6, ListLength),
			NewPointerSeg = insert(N, PointerSeg, Pointer),
			{DataSeg, NewPointerSeg, ListLength + DataLength, [Pointers, Data]};
		{list, #'capnp::namespace::Type::::list'{elementType=#'capnp::namespace::Type'{''={{_,struct},#'capnp::namespace::Type::::struct'{typeId=LTypeId}}}}} ->
			case struct_bit_size(LTypeId, Schema) of
				{composite, DWords, PWords} ->
					FoldFun = fun (V, {L, I, Data, DataLength}) ->
							{DWords1, PWords1, NewData, _NewDataLength, NewExtraData, NewExtraDataLength} = to_bytes(Schema, LTypeId, V, L+DataLength),
							io:format("~p~n", [{NewExtraData, NewExtraDataLength}]),
							{DWords, PWords} = {DWords1, PWords1},
							{L + DWords1 + PWords1, I+1, [NewData,Data|NewExtraData], NewExtraDataLength + DataLength}
					end,
					{DataLength, ListLength, Data, NewExtraDataLength} = lists:foldr(FoldFun, {0, 0, [], 0}, Value),
					io:format("~p~n", [{DataLength, ListLength, Data, NewExtraDataLength}]),
					{Pointer, Header} = composite_list_pointer(ExtraDataLength + (tuple_size(PointerSeg) - (N + 1)), DWords, PWords, ListLength),
					NewPointerSeg = insert(N, PointerSeg, Pointer),
					{DataSeg, NewPointerSeg, DataLength + NewExtraDataLength + 1, [<<Header:?UInt64>>|Data]};
				{pointer, PTypeClass, PTypeDescription, PDefaultValue} ->
					% Pointer only. Actually can encode this exactly like composite in theory; we just don't need a header.
					% Only difference between this and list-of-list case is the types and the unpacking of the struct, which must be {TypeName, Value} as it's only one pointer.
					FoldFun = fun ({_, V}, {I, Pointers, Data, DataLength}) ->
							{{}, {Pointer}, NewDataLength, NewData} = encode_field(PTypeClass, PTypeDescription, PDefaultValue, _N=0, V, _DataSeg={}, _PointerSeg={0}, DataLength+I, Schema),
							{I+1, [<<Pointer:?UInt64>>|Pointers], [Data|NewData], NewDataLength + DataLength}
					end,
					{ListLength, Pointers, Data, DataLength} = lists:foldr(FoldFun, {0, [], [], 0}, Value),
					Pointer = plain_list_pointer(ExtraDataLength + (tuple_size(PointerSeg) - (N + 1)), 6, ListLength),
					NewPointerSeg = insert(N, PointerSeg, Pointer),
					{DataSeg, NewPointerSeg, ListLength + DataLength, [Pointers, Data]};
				{SizeTag, BitSize, Fields} ->
					BurnData = fun (Rec) ->
							Values = tl(tuple_to_list(Rec)),
							{{Data}, {}, _, 0} = encode_parts(Fields, Values, {0}, {}, 0, [], Schema),
							<<Data:BitSize/little-integer>>
					end,
					Length = length(Value),
					PadLength = -(Length * BitSize) band 63,
					Pad = <<0:PadLength>>,
					ListData = [lists:map(BurnData, Value)|Pad],
					ListWords = (Length * BitSize + PadLength) bsr 6,
					Pointer = plain_list_pointer(ExtraDataLength + (tuple_size(PointerSeg) - (N + 1)), SizeTag, Length),
					NewPointerSeg = insert(N, PointerSeg, Pointer),
					{DataSeg, NewPointerSeg, ListWords, ListData}
			end;
		{list, #'capnp::namespace::Type'{''={{_,anyPointer},void}}} ->
			% TODO Encode as pointers?!
			erlang:error(not_implemented);
		{list, #'capnp::namespace::Type'{''={{_,interface},_LTypeId}}} ->
			% TODO Encode as ???!
			erlang:error(not_implemented);
		{list, #'capnp::namespace::Type'{''={{_,enum},_LTypeId}}} ->
			% TODO Encode as ints!
			erlang:error(not_implemented);
		{list, #'capnp::namespace::Type'{''={{_,IntOrVoidType},void}}} ->
			% TODO Encode as ints!
			erlang:error({not_implemented, list, IntOrVoidType})
			% TODO nested constructs (ie. groups)
			% TODO unions (discriminantValue/discriminantOffset)
	end.

encode_text(text, T) when is_binary(T) ->
	{[T, 0], byte_size(T) + 1};
encode_text(data, T) when is_binary(T) ->
	{T, byte_size(T)}.

encode_enum(TypeId, Value, Schema) ->
	% TODO store this in a more convenient format in the schema!
	% TODO support not-binaries as enum values (probably ought to be atoms or something).
	#'capnp::namespace::Node'{
		''={{2, enum},
			#'capnp::namespace::Node::::enum'{
				enumerants=Enumerants
			}
		}
	} = dict:fetch(TypeId, Schema#capnp_context.by_id),
	Index = length(lists:takewhile(fun (#'capnp::namespace::Enumerant'{name=EName}) -> Value /= EName end, Enumerants)),
	true = Index < length(Enumerants),
	Index.

struct_bit_size(TypeId, Schema) ->
	#'capnp::namespace::Node'{
		''={{1, struct},
			#'capnp::namespace::Node::::struct'{
				dataWordCount=DWords,
				pointerCount=PWords,
				fields=Fields,
				discriminantCount=DCount,
				discriminantOffset=DOffset
			}
		}
	} = dict:fetch(TypeId, Schema#capnp_context.by_id),
	if
		DWords + PWords > 1 ->
			{composite, DWords, PWords};
		PWords =:= 1 ->
			[#'capnp::namespace::Field'{
					''={{0,slot},
						#'capnp::namespace::Field::::slot'{
							offset=0,
							defaultValue=#'capnp::namespace::Value'{''={{_,TypeClass},DefaultValue}},
							type=#'capnp::namespace::Type'{''={{_,TypeClass},TypeDescription}} % No pointers, so should be fine here!
						}
					}
				}] = Fields,
			{pointer, TypeClass, TypeDescription, DefaultValue};
		true ->
			% Hard part; there are no pointers but we don't know the data length!
			% We simply need the highest extent of any struct part.
			GetExtent = fun (#'capnp::namespace::Field'{
						''={{0,slot},
							#'capnp::namespace::Field::::slot'{
								offset=N,
								defaultValue=#'capnp::namespace::Value'{''={{_,TypeClass},_}},
								type=#'capnp::namespace::Type'{''={{_,TypeClass},void}} % No pointers, so should be fine here!
							}
						}
					}) -> (1 bsl isize(TypeClass)) * (N + 1) end,
			DiscExtent = if DCount > 0 -> 16 + DOffset; true -> 0 end,
				BitExtent = lists:max([DiscExtent|lists:map(GetExtent, Fields)]),
				if
					BitExtent =:= 0 ->
						{0, 0, []};
					BitExtent =:= 1 ->
						{1, 1, Fields};
					BitExtent =< 8 ->
						{2, 8, Fields};
					BitExtent =< 16 ->
						{3, 16, Fields};
					BitExtent =< 32 ->
						{4, 32, Fields};
					true -> % Since DWords + PWords =< 1, we can't be >64.
						{5, 64, Fields}
				end
		end.

	% S is in "integer generations"; we're going to use it to to work out how much to bsl.
	encode(Type, Value, Default, Offset) ->
		ValueToWrite = encode(Type, Value, Default),
		Shifts = isize(Type),
		% Multiply Offset by the value size, and the result with 63.
		% This gives the offset within this word that the value will appear at.
		% Now shift the encoded value by that amount to align it to where we'd
		% hope it gets written.
		{Shifts, ValueToWrite bsl ((Offset bsl Shifts) band 63)}.

	% This step is somewhat complicated by erlang's lack of love for little endian data.
	% Basically, booleans end up in the wrong part of their byte.
	% Still need a lot of experiment to find the fastest way of writing this code. 
	encode(void, _, _) ->
		0;
	encode(int8, N, V) ->
		encode_integer(1 bsl 7, N, V);
	encode(int16, N, V) ->
		encode_integer(1 bsl 15, N, V);
	encode(int32, N, V) ->
		encode_integer(1 bsl 31, N, V);
	encode(int64, N, V) ->
		encode_integer(1 bsl 63, N, V);
	encode(bool, N, V) ->
		encode_uinteger(1, N, V);
	encode(uint8, N, V) ->
		encode_uinteger(1 bsl 8, N, V);
	encode(uint16, N, V) ->
		encode_uinteger(1 bsl 16, N, V);
	encode(uint32, N, V) ->
		encode_uinteger(1 bsl 32, N, V);
	encode(uint64, N, V) ->
		encode_uinteger(1 bsl 64, N, V);
	encode(_, _, _) ->
		0.

	% How many times do we bsl 1 to get the size in bits?
	isize(void) ->
		-1;
	isize(bool) ->
		0;
	isize(uint8) ->
		3;
	isize(int8) ->
		3;
	isize(uint16) ->
		4;
	isize(int16) ->
		4;
	isize(uint32) ->
		5;
	isize(int32) ->
		5;
	isize(uint64) ->
		6;
	isize(int64) ->
		6.

	encode_integer(Max, Value, Default) when is_integer(Value), Value < 0, Value >= -Max ->
		(Value+Max*2) bxor Default;
	encode_integer(Max, Value, Default) when is_integer(Value), Value >= 0, Value < Max ->
		Value bxor Default.

	encode_uinteger(Max, Value, Default) when is_integer(Value), Value >= 0, Value < Max ->
		Value bxor Default.

	insert(Offset, DataSeg, Value) ->
		% TODO setelement is sad
		setelement(Offset+1, DataSeg, element(Offset+1, DataSeg) bor Value).

	flatten_seg(L) ->
		<< <<A:?UInt64>> || A <- tuple_to_list(L) >>.