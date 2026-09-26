-- Enum updates must commit before functions reference the new value.
alter type public.operation_type add value if not exists 'depense';
