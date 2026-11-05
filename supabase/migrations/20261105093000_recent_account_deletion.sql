create or replace function public.delete_my_account()
returns void language plpgsql volatile security definer set search_path = '' as $$
declare
    account_id uuid := auth.uid();
begin
    if account_id is null then
        raise exception 'Sign in before deleting your account' using errcode = '42501';
    end if;
    if not exists (
        select 1 from auth.sessions
        where id = (auth.jwt()->>'session_id')::uuid
          and user_id = account_id
          and created_at > now() - interval '15 minutes'
    ) then
        raise exception 'Sign in again before deleting your account' using errcode = '42501';
    end if;
    delete from auth.users where id = account_id;
end;
$$;
