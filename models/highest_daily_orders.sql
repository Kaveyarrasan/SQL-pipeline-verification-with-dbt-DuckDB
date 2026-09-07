-- Interview question being verified:
-- "Find the customer(s) with the highest daily total order cost in a date range."
--
-- order_date is intentionally seeded as VARCHAR (e.g. '3/4/2019') to reproduce
-- a real failure mode: dbt's seed loader infers conservative types, and trusting
-- that inference here would silently run the date filter as a STRING comparison,
-- matching almost nothing with zero errors. The explicit strptime() cast below
-- is the fix for that bug -- see the project README for the full debugging story.

with orders_parsed as (
  select
    id
    , cust_id
    , strptime(order_date, '%-m/%-d/%Y')::date as order_date
    , total_order_cost
  from {{ ref('orders') }}
),

highest_daily_orders as (
  select * from (
    select * from (
      select distinct x.cust_id, x.order_date, x.total_cost_cust_date
           , rank() over(order by x.total_cost_cust_date desc) highest_daily_sales
      from (
        select *
             , sum(total_order_cost) over(partition by cust_id, order_date) as total_cost_cust_date
        from orders_parsed
        where order_date between '2019-02-01' and '2019-05-01'
      ) x
    ) x
    where x.highest_daily_sales = 1
  ) o
)

select c.first_name, o.total_cost_cust_date, o.order_date
from {{ ref('customers') }} c
join highest_daily_orders o on c.id = o.cust_id
