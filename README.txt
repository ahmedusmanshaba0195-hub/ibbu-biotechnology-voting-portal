IBBU Biotechnology Election Portal — real implementation

Files:
- index.html: mobile-friendly website with database-backed eligibility verification, ballot submission, duplicate-vote prevention, and results display.
- schema.sql: Supabase database schema and server-side functions.
- SETUP.md: full deployment and administration guide.

The website requires a Supabase project and a GitHub Pages deployment before it becomes a public, functioning voting website. The app deliberately does not pretend to be live before the database is configured. Follow SETUP.md from top to bottom. Never put the Supabase service_role key in the frontend.
