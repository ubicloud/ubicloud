SELECT ROUND(SUM(order_amount)::numeric, 2) as total_revenue FROM order_analytics;
SELECT ROUND(AVG(order_amount)::numeric, 2) as avg_order_value FROM order_analytics;
SELECT ROUND(AVG(delivery_days)::numeric, 1) as avg_delivery_days FROM order_analytics WHERE delivery_days IS NOT NULL;