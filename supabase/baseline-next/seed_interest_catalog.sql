-- FamilArea next seed. LOCAL DESIGN ONLY: run after familarea_baseline.sql.
begin;
insert into public.interest_categories(name,normalized_name) values
 ('Sport','sport'),('Natura e outdoor','natura e outdoor'),('Cultura e spettacolo','cultura e spettacolo'),('Cucina e gastronomia','cucina e gastronomia'),('Creatività e hobby','creativita e hobby'),('Viaggi e tempo libero','viaggi e tempo libero');
insert into public.interests(category_id,display_name,normalized_name,origin,publication_status,status)
select c.id,v.name,v.normalized_name,'catalog','published','active'
from (values
 ('Sport','Calcio','calcio'),('Sport','Padel','padel'),('Sport','Tennis','tennis'),('Sport','Ciclismo','ciclismo'),('Sport','Running','running'),
 ('Natura e outdoor','Trekking','trekking'),('Natura e outdoor','Campeggio','campeggio'),('Natura e outdoor','Sci alpino','sci alpino'),('Natura e outdoor','Giardinaggio','giardinaggio'),('Natura e outdoor','Pesca','pesca'),
 ('Cultura e spettacolo','Cinema','cinema'),('Cultura e spettacolo','Teatro','teatro'),('Cultura e spettacolo','Concerti','concerti'),('Cultura e spettacolo','Musei','musei'),('Cultura e spettacolo','Lettura','lettura'),
 ('Cucina e gastronomia','Cucina','cucina'),('Cucina e gastronomia','Pasticceria','pasticceria'),('Cucina e gastronomia','Enogastronomia','enogastronomia'),('Cucina e gastronomia','Degustazioni','degustazioni'),('Cucina e gastronomia','Ristorazione','ristorazione'),
 ('Creatività e hobby','Pittura','pittura'),('Creatività e hobby','Fotografia','fotografia'),('Creatività e hobby','Ceramica','ceramica'),('Creatività e hobby','Artigianato','artigianato'),('Creatività e hobby','Giochi di carte','giochi di carte'),
 ('Viaggi e tempo libero','Viaggi','viaggi'),('Viaggi e tempo libero','Gite','gite'),('Viaggi e tempo libero','Borghi','borghi'),('Viaggi e tempo libero','Sagre','sagre'),('Viaggi e tempo libero','Ballo','ballo')
) as v(category_name,name,normalized_name) join public.interest_categories c on c.name=v.category_name;
commit;
