DROP TABLE IF EXISTS public.order_analytics;
CREATE TABLE public.order_analytics (
    order_id uuid PRIMARY KEY,
    customer_id uuid NOT NULL,
    product_category varchar(50) NOT NULL,
    order_amount decimal(10,2) NOT NULL,
    payment_method varchar(20) NOT NULL,
    shipping_country varchar(50) NOT NULL,
    order_status varchar(20) NOT NULL,
    created_at timestamp DEFAULT current_timestamp,
    delivery_days integer,
    is_prime_customer boolean DEFAULT false
);