# IBBU Biotechnology Election Portal — real backend setup

This package contains a real database-backed voting application, not just a static demo. It uses **GitHub Pages** for free static hosting and **Supabase** for the database and secure server-side voting functions. It will not accept real votes until you complete the setup below and run a supervised test election.

## Before you start

- An authorised election administrator should own the GitHub and Supabase accounts.
- The department/Electoral Committee should approve the voter register, candidates, positions, opening/closing times, and the voting procedure.
- Do not put a Supabase `service_role` key in `index.html`, GitHub, WhatsApp, or any public place.
- Matriculation-number prefixes are only a format check. The system also requires a matching record in the private approved voter register and a unique private access code.

## 1. Create the free database

1. Open the official Supabase website: https://supabase.com/ and create a project.
2. Save the database password privately. Choose the region closest to your voters if available.
3. In the project dashboard, open **SQL Editor** and create a new query.
4. Copy all text from `schema.sql` into the editor and run it.
5. If the editor reports an error, stop and fix it before opening the election. Do not ignore failed SQL statements.

## 2. Add approved candidates

Use Supabase **Table Editor** to add candidate rows to `election_candidates`. Each candidate needs:

- `position_id`: one of `president`, `vice_president`, `general_secretary`, `financial_secretary`, `treasurer`, `pro` (or another ID created in `election_positions`).
- `full_name`: approved candidate name.
- `level`: optional year/level label.
- `manifesto`: optional short manifesto.
- `active`: true for candidates who are approved to stand.

Only enter approved public candidate information. Add/adjust positions in `election_positions` before opening the election.

## 3. Register eligible students and give them access codes

Eligible matriculation formats supported by this implementation:

- `U22/FNS/BTG/...`
- `U23/FNS/BTG/...`
- `U24/FNS/BTG/...`
- `U25/FNS/BTG/...`
- It also accepts `U/FNS/BTG/22/...`, `U/FNS/BTG/23/...`, `U/FNS/BTG/24/...`, and `U/FNS/BTG/25/...`.

The private voter register must be compiled from the official departmental list. For every approved student, generate a **different random access code** and send it privately after checking the student's identity. Never post codes in a public group. Example SQL for one voter (replace both values; this is only a template):

```sql
INSERT INTO public.eligible_voters(matric_number, access_code_hash)
VALUES (
  'U22/FNS/BTG/0000',
  encode(extensions.digest('REPLACE-WITH-UNIQUE-PRIVATE-CODE', 'sha256'), 'hex')
);
```

Use a unique code per voter, preferably 12+ random characters. Never use a shared class password. Keep the original register and the delivery of codes private. For a large voter list, prepare a carefully checked SQL import with each code hashed; do not upload plain access codes to a public repository.

## 4. Connect the web page

1. In Supabase, open **Project Settings → API** (or **Connect**, depending on dashboard layout).
2. Copy the **Project URL** and the public **anon/publishable key**.
3. Open `index.html` in a text editor and find:
   - `PASTE_SUPABASE_PROJECT_URL_HERE`
   - `PASTE_SUPABASE_ANON_KEY_HERE`
4. Replace them with your project's URL and public anon/publishable key. This public key is intended for browser use; never use the `service_role` key.
5. Save `index.html`.

## 5. Publish free with GitHub Pages

1. Sign in at https://github.com/ and create a **public** repository named `ibbu-biotechnology-election`.
2. Upload `index.html` to the repository root. Keep `schema.sql` and `SETUP.md` for the administrator; they do not need to be published.
3. Open **Settings → Pages**. Select **Deploy from a branch**, branch `main`, folder `/(root)`, then Save.
4. Wait for the Pages build to finish. GitHub will display the public website link. Share that live link with students.
5. Open the link on a phone and test it before announcing it.

Official guides: GitHub Pages https://docs.github.com/en/pages/quickstart and Supabase API keys https://supabase.com/docs/guides/api/api-keys.

## 6. Test privately before real use

1. Keep `election_config.status = 'draft'` while configuring.
2. Add test positions/candidates and at least two test voter records with different random access codes.
3. Set the status to `open` only for a controlled test:
   `UPDATE public.election_config SET status='open', updated_at=now() WHERE singleton=true;`
4. Confirm that an unregistered matriculation number is rejected, wrong codes are rejected, and a registered student can submit one ballot.
5. Try to submit a second ballot for the same test voter; it must be rejected.
6. Set status to `closed` and verify that further votes are rejected. Inspect the test counts in the database.
7. Delete/reset only test data using a planned, reviewed procedure, then import the real voter list and approved candidates.
8. Open the official election only when the committee is ready.

## Election controls

Run these only in Supabase SQL Editor as the administrator:

```sql
-- Open voting
UPDATE public.election_config SET status='open', updated_at=now() WHERE singleton=true;

-- Close voting
UPDATE public.election_config SET status='closed', updated_at=now() WHERE singleton=true;

-- Publish results after checking the count
UPDATE public.election_config SET status='results', updated_at=now() WHERE singleton=true;
```

The public page displays results only when status is `results`. Before publication, close voting and independently verify the count. Do not change election status to `results` until the Electoral Committee authorises publication.

## Important security limitations

This is a practical small-department implementation, not a certified election platform. Ballot choices are stored separately from the voter identity/participation table, but the database owner can access both tables and timestamps; this is not cryptographic end-to-end ballot secrecy. The access-code mechanism is not a replacement for official identity verification. For a high-stakes or disputed election, use an independently reviewed voting system and security audit. Protect administrator accounts with MFA, restrict dashboard access, and have the committee agree on an audit and recount procedure.
