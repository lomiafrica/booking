-- ENUM types
CREATE TYPE public.court_status AS ENUM ('available', 'reserved', 'maintenance');
CREATE TYPE public.reservation_status AS ENUM ('pending', 'confirmed', 'cancelled');

-- PROFILES table
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'client' CHECK (role IN ('client', 'admin')),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- COURTS table
CREATE TABLE IF NOT EXISTS public.courts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  price_per_hour NUMERIC NOT NULL CHECK (price_per_hour >= 0),
  image_url TEXT,
  status public.court_status DEFAULT 'available',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- RESERVATIONS table
CREATE TABLE IF NOT EXISTS public.reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  court_id UUID NOT NULL REFERENCES public.courts(id) ON DELETE CASCADE,
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  total_price NUMERIC NOT NULL CHECK (total_price >= 0),
  status public.reservation_status DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT reservations_timeframe_check CHECK (end_time > start_time)
);

-- PAYMENTS table
CREATE TABLE IF NOT EXISTS public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID NOT NULL REFERENCES public.reservations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount DECIMAL(10, 2) NOT NULL,
  currency TEXT NOT NULL DEFAULT 'XOF',
  payment_method TEXT NOT NULL CHECK (payment_method IN ('online', 'on_spot')),
  payment_provider TEXT,
  provider_payment_id TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'failed', 'refunded')),
  payment_url TEXT,
  payment_date TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now() NOT NULL
);

-- INDEXES for PAYMENTS table
CREATE INDEX IF NOT EXISTS payments_reservation_id_idx ON public.payments(reservation_id);
CREATE INDEX IF NOT EXISTS payments_user_id_idx ON public.payments(user_id);
CREATE INDEX IF NOT EXISTS payments_status_idx ON public.payments(status);

-- INDEXES for RESERVATIONS table (for foreign keys)
CREATE INDEX IF NOT EXISTS reservations_user_id_idx ON public.reservations(user_id);
CREATE INDEX IF NOT EXISTS reservations_court_id_idx ON public.reservations(court_id);

-- Function and Trigger to HANDLE NEW USER (create profile)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, role)
  VALUES (NEW.id, 
    CASE 
      WHEN NOT EXISTS (SELECT 1 FROM public.profiles) THEN 'admin'
      ELSE 'client'
    END
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Function and Trigger to UPDATE 'updated_at' timestamp on PAYMENTS table
CREATE OR REPLACE FUNCTION public.update_payments_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = public;

CREATE TRIGGER update_payments_updated_at_trigger
BEFORE UPDATE ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.update_payments_updated_at();

-- Function and Trigger to UPDATE RESERVATION STATUS when PAYMENT is completed
CREATE OR REPLACE FUNCTION public.update_reservation_status_on_payment()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
    UPDATE public.reservations
    SET status = 'confirmed'
    WHERE id = NEW.reservation_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path = public;

CREATE TRIGGER update_reservation_status_on_payment_trigger
AFTER UPDATE ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.update_reservation_status_on_payment();

-- Procedure to FIX MISSING PROFILES (definition only, call it from seed.sql)
CREATE OR REPLACE PROCEDURE public.fix_missing_profiles()
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.profiles (id, role)
  SELECT u.id, 'client' FROM auth.users u
  WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id)
  ON CONFLICT (id) DO NOTHING;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE role = 'admin') THEN
    UPDATE public.profiles
    SET role = 'admin'
    WHERE id = (
      SELECT u_inner.id FROM auth.users u_inner 
      ORDER BY u_inner.created_at 
      LIMIT 1
    );
  END IF;
END;
$$
SET search_path = public;

-- Function to check if the current user is an admin
CREATE OR REPLACE FUNCTION public.is_current_user_admin()
RETURNS boolean
LANGUAGE sql SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

-- Enable ROW LEVEL SECURITY (RLS)
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

-- POLICIES for PROFILES table
CREATE POLICY "Authenticated users can read profiles"
  ON public.profiles FOR SELECT TO authenticated
  USING (public.is_current_user_admin() OR (select auth.uid()) = id);
CREATE POLICY "Users can insert their own profile"
  ON public.profiles FOR INSERT TO authenticated WITH CHECK ((select auth.uid()) = id AND role = 'client');

-- POLICIES for COURTS table
CREATE POLICY "Anyone can read courts"
  ON public.courts FOR SELECT TO authenticated USING (true); -- Or `TO anon, authenticated` if public read desired
CREATE POLICY "Admins can insert courts"
  ON public.courts FOR INSERT TO authenticated WITH CHECK (public.is_current_user_admin());
CREATE POLICY "Admins can update courts"
  ON public.courts FOR UPDATE TO authenticated USING (public.is_current_user_admin());
CREATE POLICY "Admins can delete courts"
  ON public.courts FOR DELETE TO authenticated USING (public.is_current_user_admin());

-- POLICIES for RESERVATIONS table
CREATE POLICY "Authenticated users can read reservations"
  ON public.reservations FOR SELECT TO authenticated
  USING (public.is_current_user_admin() OR (select auth.uid()) = user_id);
CREATE POLICY "Users can insert reservations for themselves"
  ON public.reservations FOR INSERT TO authenticated WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Authenticated users can update reservations"
  ON public.reservations FOR UPDATE TO authenticated
  USING (public.is_current_user_admin() OR ((select auth.uid()) = user_id AND status = 'pending'));

-- POLICIES for PAYMENTS table
CREATE POLICY "Authenticated users can view payments"
  ON public.payments FOR SELECT TO authenticated
  USING (public.is_current_user_admin() OR user_id = (select auth.uid()));
CREATE POLICY "Users can create their own payments"
  ON public.payments FOR INSERT TO authenticated WITH CHECK (user_id = (select auth.uid()));
CREATE POLICY "Admins can update all payments"
  ON public.payments FOR UPDATE TO authenticated USING (public.is_current_user_admin());

-- GRANTS (Example for courts, adjust as needed)
GRANT SELECT ON public.courts TO authenticated;
GRANT SELECT ON public.courts TO anon; -- If courts should be publicly readable

DO $$
BEGIN
  RAISE NOTICE 'Consolidated initial schema migration complete.';
END $$; 
