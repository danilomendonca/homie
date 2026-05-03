SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: unit_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.unit_type AS ENUM (
    'unit',
    'weight',
    'volume'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name public.citext NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: inventory_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    quantity numeric(12,3) NOT NULL,
    expiration_date date,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT inventory_items_quantity_non_negative CHECK ((quantity >= (0)::numeric))
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name public.citext NOT NULL,
    category_id uuid,
    unit_type public.unit_type NOT NULL,
    low_stock_threshold numeric(12,3),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT products_low_stock_threshold_non_negative CHECK (((low_stock_threshold IS NULL) OR (low_stock_threshold >= (0)::numeric)))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: inventory_items inventory_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT inventory_items_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: index_categories_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_categories_on_name ON public.categories USING btree (name);


--
-- Name: index_inventory_items_on_expiration_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_items_on_expiration_date ON public.inventory_items USING btree (expiration_date);


--
-- Name: index_inventory_items_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_items_on_product_id ON public.inventory_items USING btree (product_id);


--
-- Name: index_inventory_items_on_product_id_active_stock; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inventory_items_on_product_id_active_stock ON public.inventory_items USING btree (product_id) WHERE (quantity > (0)::numeric);


--
-- Name: index_products_on_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_products_on_category_id ON public.products USING btree (category_id);


--
-- Name: index_products_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_name ON public.products USING btree (name);


--
-- Name: inventory_items fk_rails_62d92932b7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_items
    ADD CONSTRAINT fk_rails_62d92932b7 FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: products fk_rails_fb915499a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_rails_fb915499a4 FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260503012002'),
('20260503012001'),
('20260503012000'),
('20260503011959'),
('20260503011958');

