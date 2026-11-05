create extension if not exists pg_graphql;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

comment on schema public is '@graphql({"inflect_names": true})';

create table public.bookmarks (
    owner_id uuid not null references auth.users(id) on delete cascade,
    id uuid not null,
    url text not null check (length(url) <= 8192 and url ~ '^https?://[^/?#[:space:]]+'
        and url !~ '[[:space:]]' and url !~ '^[^:]+://[^/?#]*@'),
    title text not null check (length(title) between 1 and 1000),
    note text not null default '' check (length(note) <= 20000),
    tags text[] not null default '{}' check (cardinality(tags) <= 32),
    is_read boolean not null default false,
    is_favorite boolean not null default false,
    created_at timestamptz not null,
    metadata_state text not null check (metadata_state in ('pending', 'ready', 'failed')),
    metadata_message text check (length(metadata_message) <= 2000),
    image_url text check (length(image_url) <= 8192 and image_url ~ '^https://'
        and image_url !~ '^[^:]+://[^/?#]*@'),
    revision bigint not null check (revision > 0),
    deleted boolean not null default false,
    primary key (owner_id, id),
    unique (owner_id, url)
);

alter table public.bookmarks enable row level security;
create policy "Read own bookmarks" on public.bookmarks
    for select to authenticated using ((select auth.uid()) = owner_id);

revoke all on public.bookmarks from public, anon, authenticated;
grant usage on schema public to authenticated;
grant select on public.bookmarks to authenticated;

create table private.bookmark_operations (
    owner_id uuid not null references auth.users(id) on delete cascade,
    operation_id uuid not null,
    request_hash text not null,
    response jsonb not null,
    created_at timestamptz not null default now(),
    primary key (owner_id, operation_id)
);
alter table private.bookmark_operations enable row level security;
revoke all on private.bookmark_operations from public, anon, authenticated;

create function private.bookmark_record(item public.bookmarks)
returns jsonb language sql immutable set search_path = '' as $$
    select jsonb_build_object(
        'bookmark', jsonb_strip_nulls(jsonb_build_object(
            'id', item.id, 'url', item.url, 'title', item.title, 'note', item.note,
            'tags', item.tags, 'isRead', item.is_read, 'isFavorite', item.is_favorite,
            'createdAt', extract(epoch from item.created_at),
            'metadataState', item.metadata_state, 'metadataMessage', item.metadata_message,
            'imageURL', item.image_url
        )),
        'version', item.revision, 'isDeleted', item.deleted
    );
$$;
revoke all on function private.bookmark_record(public.bookmarks) from public, anon, authenticated;

-- Only this compare-and-swap mutation can write bookmarks. No client receives direct DML grants.
create function public."applyBookmarkChange"(
    "operationId" uuid,
    "expectedVersion" bigint,
    bookmark jsonb,
    "isDeleted" boolean
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
    account_id uuid := auth.uid();
    bookmark_id uuid;
    requested_url text;
    fingerprint text;
    previous_operation private.bookmark_operations%rowtype;
    current_record public.bookmarks%rowtype;
    result jsonb;
    record_exists boolean;
    normalized_tags text[];
begin
    if account_id is null then
        raise exception 'Sign in before syncing bookmarks' using errcode = '42501';
    end if;
    if "operationId" is null or "expectedVersion" is null or "expectedVersion" < 0
        or "isDeleted" is null or bookmark is null or pg_column_size(bookmark) > 65536 then
        raise exception 'Invalid sync operation';
    end if;
    if jsonb_typeof(bookmark->'id') is distinct from 'string'
        or jsonb_typeof(bookmark->'url') is distinct from 'string'
        or jsonb_typeof(bookmark->'title') is distinct from 'string'
        or jsonb_typeof(bookmark->'note') is distinct from 'string'
        or jsonb_typeof(bookmark->'tags') is distinct from 'array'
        or jsonb_typeof(bookmark->'createdAt') is distinct from 'number'
        or jsonb_typeof(bookmark->'isRead') is distinct from 'boolean'
        or jsonb_typeof(bookmark->'isFavorite') is distinct from 'boolean'
        or jsonb_typeof(bookmark->'metadataState') is distinct from 'string' then
        raise exception 'Bookmark fields have invalid types';
    end if;
    if jsonb_array_length(bookmark->'tags') > 32 or exists (
        select 1 from jsonb_array_elements(bookmark->'tags') tag
        where jsonb_typeof(tag) <> 'string' or length(tag #>> '{}') > 80
    ) then
        raise exception 'Use at most 32 tags of at most 80 characters';
    end if;
    bookmark_id := (bookmark->>'id')::uuid;
    requested_url := bookmark->>'url';
    normalized_tags := array(select jsonb_array_elements_text(bookmark->'tags'));
    fingerprint := encode(sha256(convert_to(jsonb_build_object(
        'bookmark', bookmark, 'expectedVersion', "expectedVersion", 'isDeleted', "isDeleted"
    )::text, 'UTF8')), 'hex');

    -- Serialize only this account, including first inserts where no row exists to lock yet.
    perform pg_advisory_xact_lock(hashtextextended(account_id::text, 0));
    select * into previous_operation from private.bookmark_operations
        where owner_id = account_id and operation_id = "operationId";
    if found then
        if previous_operation.request_hash <> fingerprint then
            raise exception 'Operation ID was reused with different content';
        end if;
        return previous_operation.response;
    end if;

    select * into current_record from public.bookmarks
        where owner_id = account_id and (id = bookmark_id or url = requested_url)
        order by (id = bookmark_id) desc limit 1 for update;
    record_exists := found;
    if (record_exists and (current_record.id <> bookmark_id or current_record.revision <> "expectedVersion"))
        or (not record_exists and "expectedVersion" <> 0) then
        result := jsonb_build_object(
            'status', 'conflict',
            'record', case when record_exists then private.bookmark_record(current_record) else null end
        );
    else
        if record_exists and current_record.url <> requested_url then
            raise exception 'A saved bookmark URL cannot be changed';
        end if;
        if record_exists then
            update public.bookmarks set
                title = bookmark->>'title', note = bookmark->>'note', tags = normalized_tags,
                is_read = (bookmark->>'isRead')::boolean,
                is_favorite = (bookmark->>'isFavorite')::boolean,
                metadata_state = bookmark->>'metadataState',
                metadata_message = bookmark->>'metadataMessage',
                image_url = bookmark->>'imageURL',
                revision = current_record.revision + 1, deleted = "isDeleted"
            where owner_id = account_id and id = bookmark_id returning * into current_record;
        else
            insert into public.bookmarks (
                owner_id, id, url, title, note, tags, is_read, is_favorite, created_at,
                metadata_state, metadata_message, image_url, revision, deleted
            ) values (
                account_id, bookmark_id, requested_url, bookmark->>'title', bookmark->>'note',
                normalized_tags, (bookmark->>'isRead')::boolean, (bookmark->>'isFavorite')::boolean,
                to_timestamp((bookmark->>'createdAt')::double precision),
                bookmark->>'metadataState', bookmark->>'metadataMessage', bookmark->>'imageURL', 1, "isDeleted"
            ) returning * into current_record;
        end if;
        result := jsonb_build_object('status', 'applied', 'record', private.bookmark_record(current_record));
    end if;

    insert into private.bookmark_operations(owner_id, operation_id, request_hash, response)
        values (account_id, "operationId", fingerprint, result);
    return result;
end;
$$;

revoke all on function public."applyBookmarkChange"(uuid, bigint, jsonb, boolean) from public, anon;
grant execute on function public."applyBookmarkChange"(uuid, bigint, jsonb, boolean) to authenticated;

create function public.delete_my_account()
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
    account_id uuid := auth.uid();
begin
    if account_id is null then
        raise exception 'Sign in before deleting your account' using errcode = '42501';
    end if;
    delete from auth.users where id = account_id;
end;
$$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

notify pgrst, 'reload schema';
