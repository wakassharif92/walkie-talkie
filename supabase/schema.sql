create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  display_name text not null default '',
  avatar_url text,
  status text not null default 'offline' check (status in ('online', 'offline')),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.contact_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at timestamptz not null default now(),
  unique (sender_id, receiver_id)
);

create table if not exists public.contacts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  contact_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, contact_id),
  check (user_id <> contact_id)
);

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.pokes (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'cleared')),
  created_at timestamptz not null default now(),
  unique (sender_id, receiver_id, status)
);

alter table public.profiles enable row level security;
alter table public.contact_requests enable row level security;
alter table public.contacts enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.pokes enable row level security;

drop policy if exists "profiles_select_authenticated" on public.profiles;
create policy "profiles_select_authenticated"
on public.profiles for select
to authenticated
using (true);

drop policy if exists "profiles_insert_self" on public.profiles;
create policy "profiles_insert_self"
on public.profiles for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self"
on public.profiles for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

drop policy if exists "requests_select_related" on public.contact_requests;
create policy "requests_select_related"
on public.contact_requests for select
to authenticated
using (auth.uid() = sender_id or auth.uid() = receiver_id);

drop policy if exists "requests_insert_sender" on public.contact_requests;
create policy "requests_insert_sender"
on public.contact_requests for insert
to authenticated
with check (auth.uid() = sender_id and sender_id <> receiver_id);

drop policy if exists "requests_update_receiver" on public.contact_requests;
create policy "requests_update_receiver"
on public.contact_requests for update
to authenticated
using (auth.uid() = receiver_id)
with check (auth.uid() = receiver_id);

drop policy if exists "contacts_select_self" on public.contacts;
create policy "contacts_select_self"
on public.contacts for select
to authenticated
using (auth.uid() = user_id or auth.uid() = contact_id);

drop policy if exists "contacts_insert_approved_related" on public.contacts;
create policy "contacts_insert_approved_related"
on public.contacts for insert
to authenticated
with check (
  (auth.uid() = user_id or auth.uid() = contact_id)
  and exists (
    select 1
    from public.contact_requests request
    where request.status = 'approved'
      and (
        (request.sender_id = user_id and request.receiver_id = contact_id)
        or
        (request.sender_id = contact_id and request.receiver_id = user_id)
      )
  )
);

drop policy if exists "contacts_delete_self" on public.contacts;
create policy "contacts_delete_self"
on public.contacts for delete
to authenticated
using (auth.uid() = user_id or auth.uid() = contact_id);

create or replace function public.send_contact_request(target_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_request_id uuid;
begin
  if target_user_id = auth.uid() then
    raise exception 'you cannot add yourself';
  end if;

  if exists (
    select 1
    from public.contacts
    where (user_id = auth.uid() and contact_id = target_user_id)
       or (user_id = target_user_id and contact_id = auth.uid())
  ) then
    raise exception 'user is already your contact';
  end if;

  delete from public.contact_requests
  where (sender_id = auth.uid() and receiver_id = target_user_id)
     or (sender_id = target_user_id and receiver_id = auth.uid());

  insert into public.contact_requests (sender_id, receiver_id, status)
  values (auth.uid(), target_user_id, 'pending')
  returning id into new_request_id;

  return new_request_id;
end;
$$;

create or replace function public.is_group_member(target_group_id uuid, target_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_members
    where group_id = target_group_id
      and user_id = target_user_id
  );
$$;

create or replace function public.is_group_admin(target_group_id uuid, target_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_members
    where group_id = target_group_id
      and user_id = target_user_id
      and role = 'admin'
  );
$$;

drop policy if exists "groups_select_member" on public.groups;
create policy "groups_select_member"
on public.groups for select
to authenticated
using (
  public.is_group_member(id, auth.uid())
);

drop policy if exists "groups_insert_self" on public.groups;
create policy "groups_insert_self"
on public.groups for insert
to authenticated
with check (auth.uid() = created_by);

drop policy if exists "groups_update_admin" on public.groups;
create policy "groups_update_admin"
on public.groups for update
to authenticated
using (
  public.is_group_admin(id, auth.uid())
);

drop policy if exists "group_members_select_member" on public.group_members;
create policy "group_members_select_member"
on public.group_members for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_group_member(group_id, auth.uid())
);

drop policy if exists "group_members_insert_admin" on public.group_members;
create policy "group_members_insert_admin"
on public.group_members for insert
to authenticated
with check (
  user_id = auth.uid()
  or public.is_group_admin(group_id, auth.uid())
);

drop policy if exists "group_members_delete_admin" on public.group_members;
create policy "group_members_delete_admin"
on public.group_members for delete
to authenticated
using (
  user_id = auth.uid()
  or public.is_group_admin(group_id, auth.uid())
);

drop policy if exists "pokes_select_related" on public.pokes;
create policy "pokes_select_related"
on public.pokes for select
to authenticated
using (auth.uid() = sender_id or auth.uid() = receiver_id);

drop policy if exists "pokes_insert_sender" on public.pokes;
create policy "pokes_insert_sender"
on public.pokes for insert
to authenticated
with check (auth.uid() = sender_id and sender_id <> receiver_id);

drop policy if exists "pokes_update_receiver" on public.pokes;
create policy "pokes_update_receiver"
on public.pokes for update
to authenticated
using (auth.uid() = receiver_id)
with check (auth.uid() = receiver_id);

create or replace function public.approve_contact_request(request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.contact_requests%rowtype;
begin
  select * into request_row
  from public.contact_requests
  where id = request_id
    and receiver_id = auth.uid()
    and status = 'pending';

  if not found then
    raise exception 'contact request not found';
  end if;

  update public.contact_requests
  set status = 'approved'
  where id = request_id;

  insert into public.contacts (user_id, contact_id)
  values (request_row.receiver_id, request_row.sender_id)
  on conflict do nothing;

  insert into public.contacts (user_id, contact_id)
  values (request_row.sender_id, request_row.receiver_id)
  on conflict do nothing;
end;
$$;

insert into public.contacts (user_id, contact_id)
select contact_id, user_id
from public.contacts
on conflict do nothing;

create or replace function public.delete_contact(other_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.contacts
  where (user_id = auth.uid() and contact_id = other_user_id)
     or (user_id = other_user_id and contact_id = auth.uid());

  delete from public.contact_requests
  where (sender_id = auth.uid() and receiver_id = other_user_id)
     or (sender_id = other_user_id and receiver_id = auth.uid());

  delete from public.pokes
  where (sender_id = auth.uid() and receiver_id = other_user_id)
     or (sender_id = other_user_id and receiver_id = auth.uid());
end;
$$;

create or replace function public.create_group(group_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_group_id uuid;
begin
  insert into public.groups (name, created_by)
  values (nullif(trim(group_name), ''), auth.uid())
  returning id into new_group_id;

  insert into public.group_members (group_id, user_id, role)
  values (new_group_id, auth.uid(), 'admin');

  return new_group_id;
end;
$$;

create or replace function public.add_group_member(target_group_id uuid, member_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  member_id uuid;
begin
  if not exists (
    select 1 from public.group_members
    where group_id = target_group_id
      and user_id = auth.uid()
      and role = 'admin'
  ) then
    raise exception 'only group admins can add members';
  end if;

  select id into member_id
  from public.profiles
  where lower(email) = lower(trim(member_email));

  if member_id is null then
    raise exception 'user not found';
  end if;

  insert into public.group_members (group_id, user_id, role)
  values (target_group_id, member_id, 'member')
  on conflict do nothing;
end;
$$;

create or replace function public.remove_group_member(target_group_id uuid, target_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if target_member_id = auth.uid() then
    delete from public.group_members
    where group_id = target_group_id
      and user_id = auth.uid();
    return;
  end if;

  if not exists (
    select 1 from public.group_members
    where group_id = target_group_id
      and user_id = auth.uid()
      and role = 'admin'
  ) then
    raise exception 'only group admins can remove members';
  end if;

  delete from public.group_members
  where group_id = target_group_id
    and user_id = target_member_id
    and role <> 'admin';
end;
$$;

create or replace function public.send_poke(target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if target_user_id = auth.uid() then
    raise exception 'cannot poke yourself';
  end if;

  insert into public.pokes (sender_id, receiver_id, status)
  values (auth.uid(), target_user_id, 'pending')
  on conflict (sender_id, receiver_id, status)
  do update set created_at = now();
end;
$$;

create or replace function public.clear_poke_from(target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.pokes
  where sender_id = target_user_id
    and receiver_id = auth.uid()
    and status = 'pending';
end;
$$;

grant execute on function public.approve_contact_request(uuid) to authenticated;
grant execute on function public.send_contact_request(uuid) to authenticated;
grant execute on function public.delete_contact(uuid) to authenticated;
grant execute on function public.create_group(text) to authenticated;
grant execute on function public.add_group_member(uuid, text) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
grant execute on function public.send_poke(uuid) to authenticated;
grant execute on function public.clear_poke_from(uuid) to authenticated;

create index if not exists profiles_email_idx on public.profiles (lower(email));
create index if not exists contact_requests_receiver_idx on public.contact_requests (receiver_id, status);
create index if not exists contacts_user_idx on public.contacts (user_id);
create index if not exists group_members_user_idx on public.group_members (user_id);
create index if not exists group_members_group_idx on public.group_members (group_id);
create index if not exists pokes_receiver_idx on public.pokes (receiver_id, status);
