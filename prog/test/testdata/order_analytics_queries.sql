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

INSERT INTO order_analytics 
(order_id, customer_id, product_category, order_amount, payment_method, shipping_country, order_status, created_at, delivery_days, is_prime_customer)
VALUES
    ('123e4567-e89b-12d3-a456-426614174000', '98765432-e89b-12d3-a456-426614174000', 'Electronics', 899.99, 'Credit Card', 'United States', 'Delivered', '2024-01-01 10:00:00', 3, true),
    ('223e4567-e89b-12d3-a456-426614174001', '88765432-e89b-12d3-a456-426614174001', 'Books', 49.99, 'PayPal', 'Canada', 'Processing', '2024-01-02 11:30:00', NULL, false),
    ('323e4567-e89b-12d3-a456-426614174002', '78765432-e89b-12d3-a456-426614174002', 'Clothing', 159.99, 'Debit Card', 'United Kingdom', 'Shipped', '2024-01-02 14:15:00', 5, true),
    ('423e4567-e89b-12d3-a456-426614174003', '68765432-e89b-12d3-a456-426614174003', 'Electronics', 1299.99, 'Credit Card', 'Germany', 'Delivered', '2024-01-03 09:45:00', 4, true),
    ('523e4567-e89b-12d3-a456-426614174004', '58765432-e89b-12d3-a456-426614174004', 'Home & Garden', 79.99, 'PayPal', 'France', 'Cancelled', '2024-01-03 16:20:00', NULL, false),
    ('623e4567-e89b-12d3-a456-426614174005', '48765432-e89b-12d3-a456-426614174005', 'Books', 29.99, 'PayPal', 'United States', 'Delivered', '2024-01-04 13:10:00', 2, false),
    ('723e4567-e89b-12d3-a456-426614174006', '38765432-e89b-12d3-a456-426614174006', 'Electronics', 549.99, 'Credit Card', 'Canada', 'Shipped', '2024-01-04 15:30:00', 4, true),
    ('823e4567-e89b-12d3-a456-426614174007', '28765432-e89b-12d3-a456-426614174007', 'Clothing', 89.99, 'Debit Card', 'United States', 'Processing', '2024-01-05 10:45:00', NULL, false),
    ('923e4567-e89b-12d3-a456-426614174008', '18765432-e89b-12d3-a456-426614174008', 'Home & Garden', 199.99, 'Credit Card', 'Germany', 'Delivered', '2024-01-05 14:20:00', 6, true),
    ('023e4567-e89b-12d3-a456-426614174009', '08765432-e89b-12d3-a456-426614174009', 'Electronics', 799.99, 'PayPal', 'France', 'Delivered', '2024-01-06 11:15:00', 5, false);

SELECT ROUND(SUM(order_amount)::numeric, 2) as total_revenue FROM order_analytics;
SELECT ROUND(AVG(order_amount)::numeric, 2) as avg_order_value FROM order_analytics;
SELECT ROUND(AVG(delivery_days)::numeric, 1) as avg_delivery_days FROM order_analytics WHERE delivery_days IS NOT NULL;