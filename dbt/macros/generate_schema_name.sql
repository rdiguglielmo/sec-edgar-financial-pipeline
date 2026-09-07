{#
    dbt's default behaviour prefixes a custom schema with the target schema, so
    a model configured with +schema: staging would land in main_staging. That
    reads badly next to the raw schema the Python loader writes, which is just
    "raw".

    This override uses the configured schema verbatim, giving three plainly
    named layers in the same database file: raw, staging, marts.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none -%}
        {{ target.schema | trim }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
