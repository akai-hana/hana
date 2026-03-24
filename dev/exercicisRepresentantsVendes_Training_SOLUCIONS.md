# Cas Representants de vendes (Training)
---
## Descripció de les taules de la base de dades de pràctiques

La base de dades relacional amb la que anem a treballar a les pràctiques
consta de cinc taules: CLIENTE, OFICINA,
PEDIDO, PRODUCTO i REPVENTA.

Els camps de cadascuna d'aquestes taules s'especifiquen a continuació:

CLIENTE( <ins>CLIECOD</ins>, NOMBRE, REPCOD, LIMCRED)

OFICINA(<ins>OFINUM</ins>, CIUDAD, REGION, DIRECTOR, OBJETIVO, VENTAS)

PEDIDO(<ins>PEDNUM</ins>, FECHA, CLIECOD, REPCOD, FABCOD, PRODCOD, CANT, IMPORTE)

PRODUCTO(<ins>FABCOD, PRODCOD</ins>, DESCRIP, PRECIO, EXIST)

REPVENTA(<ins>REPCOD</ins>,NOMBRE, EDAD, OFINUM, PUESTO, FCONTRATO, JEFE,
CUOTA ,VENTAS)

La informació continguda en aquestes taules correspon a una empresa de venda de recanvis. L'empresa té diverses oficines situades a
diferents ciutats. Els empleats són representants que es dediquen a vendre els productes de diferents fabricants als seus clients. A
continuació es detalla la informació continguda a cadascuna de les taules, de manera que es comprendrà millor el funcionament de l'empresa i quines són les dades del vostre interès.

__CLIENTE__: taula amb informació sobre els clients. Cada client té assignat un codi únic CLIECOD. Del client interessa saber el
NOMBRE, el representant (REPCOD) que va contactar amb ell per primera vegada i el límit de crèdit que se li pot concedir (LIMCRED).

__OFICINA__: Conté les dades sobre cadascuna de les oficines que l'empresa té. Cada oficina té assignat un identificador únic OFINUM. D'ella interessa saber-ne el nom, que és el de la CIUTAT en què està situada, la REGIÓ a què ven (Este, Oeste), el representant director de l'oficina i el total acumulat de l'import de les VENTAS realitzades pels representants assignats a aquesta. A més, cada oficina té marcat un OBJECTIVO de venda, que correspon al
total de l'import de les vendes que es pretén assolir pels representants de l'oficina.

__PEDIDO__: Taula on es guarda la informació referent a les comandes realitzades a l'empresa. A cada comanda se li assigna un número
que és únic (PEDNUM). Les dades d'una comanda són les següents: FECHA en què es va prendre la comanda, el client que la va realitzar (CLIECOD), el representant que va fer la venda (REPCOD), el producte sol·licitat (FABCOD, PRODCOD és clau primària), quantitat d'unitats demanades (CANT)
i IMPORTE total de la comanda. A cada comanda se sol·licita un sol tipus de producte.

__PRODUCTO__ Taula que conté les dades sobre els productes que l'empresa ven. Aquests productes li són subministrats per diferents fabricants, cadascun dels quals té un codi diferent (FABCOD).
Cada fabricant utilitza uns codis propis per identificar els seus productes (PRODCOD). Ja que hi ha la possibilitat que dos fabricants diferents
utilitzin els mateixos codis de producte, l'identificador del producto és la suma de tos dos, el de fabricant i el del producte
(FABCOD,PRODCOD), per identificar de manera única els articles que ven. De cada un se'n guarda una descripció (DESCRIP), el PRECIO per unitat i les seves existències que hi ha al magatzem
(EXIST).

__REPVENTA__ és la taula on es guarden els
dades dels representants de l'empresa. Cadascú té assignat un
codi que és únic (REPCOD). Se'n vol saber el NOMBRE, l'EDAD,
l'oficina a què està assignat (OFINUM), el PUESTO que ocupa, la
data de contracte (FCONTRATO), el seu cap, la CUOTA de
vendes a assolir i el total de l'import de les VENTAS que ha
realitzat.

![casPractic](casPractic.png)

La cardinalitat de totes aquestes relacions és d'un a molts (1:n):

1\. Cada representant pertany a una sola oficina; a cada oficina
treballen diversos representants.
2\. Cada representant pot tenir o no; un representant
pot ser cap de varis representants o de cap.

3\. Cada oficina és dirigida per un sol director; un representant pot
dirigir diverses oficines.

4\. Cada comanda és sol·licitada per un sol client; un client pot
sol·licitar diverses comandes.

5\. Cada comanda és presa per un sol representant; un representant
pot prendre diverses comandes.

6\. Cada comanda sol·licita un sol producte; un producte pot ser
sol·licitat en diverses comandes.

7\. Cada client és contactat per primera vegada per un sol representant;
un representant pot haver contactat per primera vegada amb diversos
clients.

# Exercicis (comenceu per l'apartat `G-DML`)
---
## A. Consultes simples

1\. Obtenir les dades dels productes les existències dels quals estiguin entre 25 i
40 unitats.

```sql
SELECT * FROM producto WHERE exist BETWEEN 25 AND 40;
```

2\. Obtenir els codis dels representants que han pres alguna comanda
(evitant-ne la repetició).

```sql
SELECT DISTINCT repcod FROM pedido;
```

3\. Obtenir les dades de les comandes realitzades pel client el
codi és el 2111.

```sql
SELECT * FROM pedido WHERE cliecod = 2111;
```

4\. Obtenir les dades de les comandes realitzades pel client el
codi és el 2111 i que han estat presos pel representant el
codi és el 103.

```sql
SELECT * FROM pedido WHERE cliecod = 2111 AND repcod = 103;
```

5\. Obtenir les dades de les comandes realitzades pel client el
codi és el 2111, que han estat presos pel representant el codi del qual
és el 103 i que sol·liciten articles del fabricant el codi del qual és ACI.

```sql
SELECT * FROM pedido WHERE cliecod = 2111 AND repcod = 103 AND fabcod = 'aci';
```

6\. Obtenir una llista de totes les comandes ordenades per client i, per
cada client, ordenats per la data de la comanda (ascendentment)

```sql
SELECT * FROM pedido ORDER BY cliecod, fecha ASC;
```

7\. Obtenir les dades dels representants que pertanyen a loficina
de codi 12 i 13 (cada representant només pertany a una oficina).

```sql
SELECT * FROM repventa WHERE ofinum IN (12, 13);
```

8\. Obtenir les dades de productes dels quals no hi ha existències o bé
aquestes són desconegudes.

```sql
SELECT * FROM producto WHERE exist = 0 OR exist IS NULL;
```

9\. Mostrar els representants que van ser contractats el 2003 (sumem
5000 a la data de contracte)

```sql
SELECT * FROM repventa
WHERE EXTRACT(YEAR FROM (fcontrato + 5000)) = 2003;
```

10\. Mostrar el nom i els dies que porta contractats els representants

```sql
SELECT nombre, (CURRENT_DATE - fcontrato) AS dies_contractats FROM repventa;
```

## B. Consultes Multitaula

1. Mostra dels representants el seu nom, la ciutat de la seva oficina, així com la seva regió.

```sql
SELECT r.nombre, o.ciudad, o.region
FROM repventa r JOIN oficina o ON r.ofinum = o.ofinum;
```

2. Obtenir una llista de totes les comandes, mostrant el número de
     comanda, el seu import, el nom del client que el va fer i el límit
     de crèdit del client.

```sql
SELECT p.pednum, p.importe, c.nombre, c.limcred
FROM pedido p JOIN cliente c ON p.cliecod = c.cliecod;
```

3. Obtenir una llista de representants ordenada alfabèticament,
     en què es mostri el nom del representant, codi de la
     oficina on treballa, ciutat i la regió on ven.

```sql
SELECT r.nombre, r.ofinum, o.ciudad, o.region
FROM repventa r JOIN oficina o ON r.ofinum = o.ofinum
ORDER BY r.nombre;
```

4. Obtenir una llista de les oficines (ciutats, no codis) que tenen
     un objectiu superior a 360.000 euros. Per a cada oficina mostrar la
     ciutat, el seu objectiu, el nom del director i lloc del mateix.

```sql
SELECT o.ciudad, o.objetivo, r.nombre AS director, r.puesto
FROM oficina o JOIN repventa r ON o.director = r.repcod
WHERE o.objetivo > 360000;
```

5. Obtenir una llista de totes les comandes mostrant el seu número, el
     import i la descripció dels productes sol·licitats.

```sql
SELECT p.pednum, p.importe, pr.descrip
FROM pedido p JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod;
```

6. Obtenir una llista de les comandes amb imports superiors
a 4000. Mostrar el nom del client que va sol·licitar la comanda,
número de la comanda, import de la mateixa, la descripció del producte
sol·licitat i el nom del representant que el va prendre. Ordeneu la
llista per client alfabèticament i després per import de més gran a més petit.

```sql
SELECT c.nombre AS client, p.pednum, p.importe, pr.descrip, r.nombre AS representant
FROM pedido p
JOIN cliente c ON p.cliecod = c.cliecod
JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod
JOIN repventa r ON p.repcod = r.repcod
WHERE p.importe > 4000
ORDER BY c.nombre ASC, p.importe DESC;
```

7. Obtenir una llista de les comandes amb imports superiors
a 2000 euros, mostrant el número de comanda, import, nom del
client que ho va sol·licitar i el nom del representant que va contactar
amb el client per primera vegada.

```sql
SELECT p.pednum, p.importe, c.nombre AS client, r.nombre AS primer_representant
FROM pedido p
JOIN cliente c ON p.cliecod = c.cliecod
JOIN repventa r ON c.repcod = r.repcod
WHERE p.importe > 2000;
```

8. Obtenir una llista de les comandes amb imports superiors a 150
     euros, mostrant el codi de la comanda, l'import, el nom del
     client que ho va sol·licitar, el nom del representant que va contactar
     amb ell per primera vegada i la ciutat de loficina on el
     representant treballa.

```sql
SELECT p.pednum, p.importe, c.nombre AS client, r.nombre AS representant, o.ciudad
FROM pedido p
JOIN cliente c ON p.cliecod = c.cliecod
JOIN repventa r ON c.repcod = r.repcod
JOIN oficina o ON r.ofinum = o.ofinum
WHERE p.importe > 150;
```

9. Llista les comandes preses durant el mes d'octubre de l'any 2003 ,
     mostrant només el número de la comanda, el seu import, el nom del
     client que ho va realitzar, la data i la descripció del producte
     sol·licitat

```sql
-- Nota: les dates reals de la BD estan desplaçades; s'afegeixen 5000 dies per obtenir l'any 2003
SELECT p.pednum, p.importe, c.nombre, p.fecha, pr.descrip
FROM pedido p
JOIN cliente c ON p.cliecod = c.cliecod
JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod
WHERE EXTRACT(YEAR FROM (p.fecha + 5000)) = 2003
  AND EXTRACT(MONTH FROM (p.fecha + 5000)) = 10;
```

10. Obtenir una llista de totes les comandes preses per representants de
     oficines de la regió Est, mostrant només el número del
     comanda, la descripció del producte i el nom del representant
     que ho va prendre

```sql
SELECT p.pednum, pr.descrip, r.nombre AS representant
FROM pedido p
JOIN repventa r ON p.repcod = r.repcod
JOIN oficina o ON r.ofinum = o.ofinum
JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod
WHERE o.region = 'Este';
```

11. Obtenir les comandes preses els mateixos dies en què un nou
     representant va ser contractat. Mostrar número de comanda, import,
     data comanda.

```sql
SELECT pednum, importe, fecha
FROM pedido
WHERE fecha IN (SELECT fcontrato FROM repventa);
```

12. Obtenir una llista amb parelles de representants i oficines on
     la quota del representant és més gran o igual que l'objectiu de la
     oficina, sigui o no l'oficina on treballa. Mostra Nom del
     representant, quota del mateix, Ciutat de l'oficina, objectiu de la
     mateixa.

```sql
SELECT r.nombre, r.cuota, o.ciudad, o.objetivo
FROM repventa r, oficina o
WHERE r.cuota >= o.objetivo;
```

13. Mostra el nom, les vendes i la ciutat de l'oficina de cada representant de l'empresa.

```sql
SELECT r.nombre, r.ventas, o.ciudad
FROM repventa r JOIN oficina o ON r.ofinum = o.ofinum;
```

14. Obtenir una llista de la descripció dels productes per als quals
     existeix alguna comanda en què se sol·licita una quantitat més gran a les
     existències del producte.

```sql
SELECT DISTINCT pr.descrip
FROM pedido p JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod
WHERE p.cant > pr.exist;
```

15. Llista els noms dels representants que tenen una quota
     superior a la del director.

```sql
SELECT r.nombre
FROM repventa r JOIN repventa j ON r.jefe = j.repcod
WHERE r.cuota > j.cuota;
```
     
16. Obtenir una llista dels representants que treballen en una oficina
     diferent de l'oficina on treballa el seu director, mostrant
     també el nom del director i el codi de l'oficina on
     treballa cadascun.

```sql
SELECT r.nombre, j.nombre AS director, r.ofinum AS oficina_rep, j.ofinum AS oficina_director
FROM repventa r JOIN repventa j ON r.jefe = j.repcod
WHERE r.ofinum != j.ofinum;
```

17. El mateix exercici anterior, però en comptes d'ofinum, la ciutat.

```sql
SELECT r.nombre, j.nombre AS director, o1.ciudad AS ciutat_rep, o2.ciudad AS ciutat_director
FROM repventa r
JOIN repventa j ON r.jefe = j.repcod
JOIN oficina o1 ON r.ofinum = o1.ofinum
JOIN oficina o2 ON j.ofinum = o2.ofinum
WHERE r.ofinum != j.ofinum;
```

18. Mostrar el nom i el lloc de què són cap.

```sql
SELECT DISTINCT j.nombre, r.puesto AS lloc_que_dirigeix
FROM repventa r JOIN repventa j ON r.jefe = j.repcod;
```

## C. Funcions de grup

1\. Mostrar la suma de les quotes i la suma de les vendes totals de
tots els representants.

```sql
SELECT SUM(cuota) AS total_quotes, SUM(ventas) AS total_vendes FROM repventa;
```

2\. Quin és l'import total de les comandes preses per Bill Adams?

```sql
SELECT SUM(p.importe) AS total_import
FROM pedido p JOIN repventa r ON p.repcod = r.repcod
WHERE r.nombre = 'Bill Adams';
```

3\. Calcula el preu mitjà dels productes del fabricant "aci".

```sql
SELECT AVG(precio) AS preu_mitja FROM producto WHERE fabcod = 'aci';
```

4\. Quin és l'import mitjà de la comanda sol·licitada pel client
"acme mfg."

```sql
SELECT AVG(p.importe) AS import_mitja
FROM pedido p JOIN cliente c ON p.cliecod = c.cliecod
WHERE LOWER(c.nombre) = 'acme mfg.';
```

5\. Mostrar la quota màxima i la quota mínima de les quotes dels
representants.

```sql
SELECT MAX(cuota) AS quota_maxima, MIN(cuota) AS quota_minima FROM repventa;
```

6\. Quina és la data de la comanda més antiga que es té registrada?

```sql
SELECT MIN(fecha) AS comanda_mes_antiga FROM pedido;
```

7\. Quin és el millor rendiment de vendes de tots els representants?
(considerar-ho com el percentatge de vendes sobre la quota).

```sql
SELECT MAX(ventas / cuota * 100) AS millor_rendiment FROM repventa WHERE cuota IS NOT NULL;
```

8\. Quants clients té lempresa?

```sql
SELECT COUNT(*) AS num_clients FROM cliente;
```

9\. Quants representants han obtingut un import de vendes superior a
la seva pròpia quota?

```sql
SELECT COUNT(*) AS num_representants FROM repventa WHERE ventas > cuota;
```

10\. Quantes comandes s'han pres de més de 150 euros?

```sql
SELECT COUNT(*) AS num_comandes FROM pedido WHERE importe > 150;
```

11\. Troba el nombre total de comandes, l'import mitjà, l'import total
dels mateixos.

```sql
SELECT COUNT(*) AS total_comandes, AVG(importe) AS import_mitja, SUM(importe) AS import_total
FROM pedido;
```

12\. Quants llocs de treball diferents hi ha a l'empresa?

```sql
SELECT COUNT(DISTINCT puesto) AS llocs_diferents FROM repventa;
```

13\. Quantes oficines tenen representants que superen les seves
pròpies quotes?

```sql
SELECT COUNT(DISTINCT ofinum) AS num_oficines
FROM repventa
WHERE ventas > cuota;
```

14\. Quin és l'import mitjà de les comandes preses per cada
representant?

```sql
SELECT repcod, AVG(importe) AS import_mitja
FROM pedido
GROUP BY repcod;
```

15\. Quin és el rang de les quotes dels representants assignats a
cada oficina (mínim i màxim)?

```sql
SELECT ofinum, MIN(cuota) AS quota_minima, MAX(cuota) AS quota_maxima
FROM repventa
GROUP BY ofinum;
```

16\. Quants representants hi ha assignats a cada oficina? Mostra Ciutat
i nombre de representants.

```sql
SELECT o.ciudad, COUNT(r.repcod) AS num_representants
FROM oficina o JOIN repventa r ON o.ofinum = r.ofinum
GROUP BY o.ciudad;
```

17\. Quants clients ha contactat per primer cop cada representant?
Mostra el codi de representant, nom i número de clients.

```sql
SELECT r.repcod, r.nombre, COUNT(c.cliecod) AS num_clients
FROM repventa r JOIN cliente c ON r.repcod = c.repcod
GROUP BY r.repcod, r.nombre;
```

18\. Calcula el total de l'import de les comandes sol·licitades per cada
client a cada representant.

```sql
SELECT cliecod, repcod, SUM(importe) AS total_import
FROM pedido
GROUP BY cliecod, repcod;
```

19\. Llista l'import total de les comandes preses per cada
representant.

```sql
SELECT repcod, SUM(importe) AS total_import
FROM pedido
GROUP BY repcod;
```

20\. Per a cada oficina amb dos o més representants, calculeu el total de
les quotes i el total de les vendes de tots els representants.

```sql
SELECT ofinum, SUM(cuota) AS total_quotes, SUM(ventas) AS total_vendes
FROM repventa
GROUP BY ofinum
HAVING COUNT(repcod) >= 2;
```

21\. Mostra el nombre de comandes que superen el 75% de les existències.

```sql
SELECT COUNT(*) AS num_comandes
FROM pedido p JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod
WHERE p.cant > pr.exist * 0.75;
```

## D. Subconsultes


0. Mostrar el nom i el lloc dels que són cap (ja està fet amb self join, ara amb subconsultes)

```sql
SELECT nombre, puesto
FROM repventa
WHERE repcod IN (SELECT DISTINCT jefe FROM repventa WHERE jefe IS NOT NULL);
```

1\. Obtenir una llista dels representants les quotes dels quals són iguals o
superiors a lobjectiu de loficina dAtlanta.

```sql
SELECT * FROM repventa
WHERE cuota >= (SELECT objetivo FROM oficina WHERE ciudad = 'Atlanta');
```

2\. Obtenir una llista de tots els clients (nom) que van ser
contactats per primera vegada per Bill Adams.

```sql
SELECT nombre FROM cliente
WHERE repcod = (SELECT repcod FROM repventa WHERE nombre = 'Bill Adams');
```

3\. Obtenir una llista de tots els productes del fabricant ACI les del qual
existències superen les existències del producte 41004 del mateix
fabricant.

```sql
SELECT * FROM producto
WHERE fabcod = 'aci'
  AND exist > (SELECT exist FROM producto WHERE fabcod = 'aci' AND TRIM(prodcod) = '41004');
```

4\. Obtenir una llista dels representants que treballen a les oficines
que han aconseguit superar el seu objectiu de vendes.

```sql
SELECT * FROM repventa
WHERE ofinum IN (SELECT ofinum FROM oficina WHERE ventas > objetivo);
```

5\. Obtenir una llista dels representants que no treballen a les
oficines dirigides per Larry Fitch.

```sql
SELECT * FROM repventa
WHERE ofinum NOT IN (
    SELECT ofinum FROM oficina
    WHERE director = (SELECT repcod FROM repventa WHERE nombre = 'Larry Fitch')
);
```

6\. Obtenir una llista de tots els clients que han demanat comandes
del fabricant ACI entre gener i juny del 2003.

```sql
-- Nota: s'afegeixen 5000 dies per corregir el desplaçament temporal de les dades
SELECT DISTINCT c.nombre FROM cliente c
WHERE c.cliecod IN (
    SELECT cliecod FROM pedido
    WHERE fabcod = 'aci'
      AND (fecha + 5000) BETWEEN '2003-01-01' AND '2003-06-30'
);
```

7\. Obtenir una llista dels productes dels quals s'ha pres una comanda
de 150 euros o més.

```sql
SELECT DISTINCT pr.*
FROM producto pr
WHERE (pr.fabcod, pr.prodcod) IN (
    SELECT fabcod, prodcod FROM pedido WHERE importe >= 150
);
```

8\. Obtenir una llista dels clients contactats per Sue Smith que no
han sol·licitat comandes amb imports superiors a 18 euros.

```sql
SELECT c.nombre FROM cliente c
WHERE c.repcod = (SELECT repcod FROM repventa WHERE nombre = 'Sue Smith')
  AND c.cliecod NOT IN (
    SELECT cliecod FROM pedido WHERE importe > 18
);
```

9\. Obtenir una llista de les oficines on hi hagi algun representant
la quota del qual sigui més del 55% de l'objectiu de l'oficina. Per comprovar el vostre
exercici, feu una Consulta prèvia el resultat de la qual valideu l'exercici.

```sql
-- Consulta prèvia de validació:
SELECT r.nombre, r.cuota, o.ciudad, o.objetivo, (r.cuota / o.objetivo * 100) AS percentatge
FROM repventa r JOIN oficina o ON r.ofinum = o.ofinum
ORDER BY o.ciudad;

-- Solució:
SELECT * FROM oficina o
WHERE EXISTS (
    SELECT 1 FROM repventa r
    WHERE r.ofinum = o.ofinum
      AND r.cuota > o.objetivo * 0.55
);
```

10\. Obtenir una llista dels representants que han pres alguna comanda
l'import del qual sigui més del 10% de la seva quota.

```sql
SELECT DISTINCT r.*
FROM repventa r
WHERE EXISTS (
    SELECT 1 FROM pedido p
    WHERE p.repcod = r.repcod
      AND p.importe > r.cuota * 0.10
);
```

11\. Obtenir una llista de les oficines on el total de vendes
dels seus representants han aconseguit un import de vendes que supera el
50% de lobjectiu de loficina. Mostrar també l'objectiu de cada
oficina (suposeu que el camp vendes d'oficina no existeix).

```sql
SELECT o.ofinum, o.ciudad, o.objetivo, SUM(r.ventas) AS total_vendes_reps
FROM oficina o JOIN repventa r ON o.ofinum = r.ofinum
GROUP BY o.ofinum, o.ciudad, o.objetivo
HAVING SUM(r.ventas) > o.objetivo * 0.50;
```

12\. Quina és la descripció del primer producte sol·licitat en una comanda?  

```sql
SELECT pr.descrip
FROM producto pr
JOIN pedido p ON pr.fabcod = p.fabcod AND pr.prodcod = p.prodcod
WHERE p.fecha = (SELECT MIN(fecha) FROM pedido);
```

13\. Quin representant té el millor percentatge de vendes?

```sql
SELECT nombre, (ventas / cuota * 100) AS percentatge_vendes
FROM repventa
WHERE cuota IS NOT NULL
ORDER BY percentatge_vendes DESC
LIMIT 1;
```

14\. Quin representant té el pitjor percentatge de vendes?

```sql
SELECT nombre, (ventas / cuota * 100) AS percentatge_vendes
FROM repventa
WHERE cuota IS NOT NULL
ORDER BY percentatge_vendes ASC
LIMIT 1;
```

15. Quin producte (Descripció) té més comandes?

```sql
SELECT pr.descrip, COUNT(*) AS num_comandes
FROM pedido p JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod
GROUP BY pr.descrip
ORDER BY num_comandes DESC
LIMIT 1;
```

16 . Quin producte s'ha venut més?

```sql
SELECT pr.descrip, SUM(p.cant) AS total_unitats_venudes
FROM pedido p JOIN producto pr ON p.fabcod = pr.fabcod AND p.prodcod = pr.prodcod
GROUP BY pr.descrip
ORDER BY total_unitats_venudes DESC
LIMIT 1;
```

## E. Intersecció, unió i diferència

1. Obtenir una llista de tots els productes el preu dels quals excedeixi els 20
     euros i dels quals hi ha alguna comanda amb un import superior a 200
     euros.

```sql
SELECT * FROM producto WHERE precio > 20
INTERSECT
SELECT pr.* FROM producto pr
JOIN pedido p ON pr.fabcod = p.fabcod AND pr.prodcod = p.prodcod
WHERE p.importe > 200;
```

2. Obtenir una llista de tots els productes el preu dels quals més IVA excedeixi
     de 20 euros o bé hi hagi alguna comanda l'import de la qual més IVA excedeixi els
     180 euros.

```sql
SELECT * FROM producto WHERE precio * 1.21 > 20
UNION
SELECT pr.* FROM producto pr
JOIN pedido p ON pr.fabcod = p.fabcod AND pr.prodcod = p.prodcod
WHERE p.importe * 1.21 > 180;
```

3. Obtenir els codis dels representants que són directors de
     oficina i que no han pres cap comanda.

```sql
SELECT director AS repcod FROM oficina
EXCEPT
SELECT DISTINCT repcod FROM pedido WHERE repcod IS NOT NULL;
```

4. Mostrar el representant que ven més i el que ven menys, deixant-lo clarament indicat.

```sql
SELECT nombre, ventas, 'Millor venedor' AS etiqueta
FROM repventa WHERE ventas = (SELECT MAX(ventas) FROM repventa)
UNION
SELECT nombre, ventas, 'Pitjor venedor' AS etiqueta
FROM repventa WHERE ventas = (SELECT MIN(ventas) FROM repventa);
```


## F. Exercicis Extra

0. Clients que no han fet cap comanda.

```sql
SELECT * FROM cliente
WHERE cliecod NOT IN (SELECT DISTINCT cliecod FROM pedido);
```

1\. Obtenir una llista amb els noms de les oficines on cap  
representant hagi pres comandes de productes del fabricant BIC.

```sql
SELECT o.ciudad FROM oficina o
WHERE o.ofinum NOT IN (
    SELECT DISTINCT r.ofinum
    FROM repventa r
    JOIN pedido p ON r.repcod = p.repcod
    WHERE p.fabcod = 'bic'
);
```

2\. Obtenir els noms dels clients que han sol·licitat comandes a
representants d'oficines que venen a la regió Oest o que van ser
contactats per primera vegada pels directors de les oficines esmentades.

```sql
SELECT DISTINCT c.nombre FROM cliente c
JOIN pedido p ON c.cliecod = p.cliecod
JOIN repventa r ON p.repcod = r.repcod
JOIN oficina o ON r.ofinum = o.ofinum
WHERE o.region = 'Oeste'
UNION
SELECT DISTINCT c.nombre FROM cliente c
JOIN repventa r ON c.repcod = r.repcod
JOIN oficina o ON r.repcod = o.director
WHERE o.region = 'Oeste';
```

3\. Obtenir els noms dels clients que només han fet comandes al
representant que va contactar amb ells la primera vegada.

```sql
SELECT c.nombre FROM cliente c
WHERE NOT EXISTS (
    SELECT 1 FROM pedido p
    WHERE p.cliecod = c.cliecod
      AND p.repcod != c.repcod
);
```

4\. Obtenir els noms dels clients que han sol·licitat tots els seus
comandes a representants que pertanyen a la mateixa oficina.

```sql
SELECT c.nombre FROM cliente c
WHERE (
    SELECT COUNT(DISTINCT r.ofinum)
    FROM pedido p JOIN repventa r ON p.repcod = r.repcod
    WHERE p.cliecod = c.cliecod
) = 1;
```

5\. Obtenir per a cada oficina la quantitat d'unitats venudes pels seus
representants de productes del fabricant ACI ( de les oficines es
mostra el nom).

```sql
SELECT o.ciudad, SUM(p.cant) AS total_unitats_aci
FROM pedido p
JOIN repventa r ON p.repcod = r.repcod
JOIN oficina o ON r.ofinum = o.ofinum
WHERE p.fabcod = 'aci'
GROUP BY o.ciudad;
```

6\. Mostrar una llista amb els noms dels representants juntament amb els
noms dels seus directors. Si un representant no té director,
també ha d'aparèixer a la llista (evidentment, al seu costat no
apareixerà cap nom).

```sql
SELECT r.nombre AS representant, j.nombre AS director
FROM repventa r LEFT JOIN repventa j ON r.jefe = j.repcod;
```

## G. Exercicis DML

1. El fabricant REI ha fabricat 100 altaveus de 65€, amb codi 3G123

```sql
INSERT INTO producto (fabcod, prodcod, descrip, precio, exist)
VALUES ('rei', '3G123', 'Altaveus', 65.00, 100);
```

2. Tom Snyder passa a tenir quota, que és equivalent a un 25% del salari.

```sql
-- S'interpreta "salari" com el camp ventas (no hi ha camp de salari explícit)
UPDATE repventa
SET cuota = ventas * 0.25
WHERE nombre = 'Tom Snyder';
```

3. A totes les oficines de l'Oest se'ls apuja el seu objectiu un 15%.

```sql
UPDATE oficina SET objetivo = objetivo * 1.15 WHERE region = 'Oeste';
```

4. Avui es contracta Andrew Bynum, de 30 anys, el seu número de representant és 111, treballa de Rep Ventas i té una quota de 1800. Encara no se sap ni el seu cap ni a quina oficina anirà.

```sql
INSERT INTO repventa (repcod, nombre, edad, ofinum, puesto, fcontrato, jefe, cuota, ventas)
VALUES (111, 'Andrew Bynum', 30, NULL, 'Rep Ventas', CURRENT_DATE, NULL, 1800.00, NULL);
```

5. La data del contracte de Paul Cruz es modifica i passa a ser el dia 11/12/2013

```sql
UPDATE repventa SET fcontrato = '2013-12-11' WHERE nombre = 'Paul Cruz';
```

6. S'acomiada Sue Smith. Per això, ho descomposem en les tasques següents:

   6.1. Crear un 'Sense Representant' per substituir-lo per Sue Smith.

```sql
INSERT INTO repventa (repcod, nombre, edad, ofinum, puesto, fcontrato, jefe, cuota, ventas)
VALUES (999, 'Sense Representant', NULL, NULL, NULL, CURRENT_DATE, NULL, NULL, NULL);
```

   6.2. Els clients que estaven assignats a Sue Smith passar-los a 'Sense Representant'.

```sql
UPDATE cliente SET repcod = 999
WHERE repcod = (SELECT repcod FROM repventa WHERE nombre = 'Sue Smith');
```

   6.3. Les comandes que estaven realitzades per Sue Smith passar-les a 'Sin Representante'.

```sql
UPDATE pedido SET repcod = 999
WHERE repcod = (SELECT repcod FROM repventa WHERE nombre = 'Sue Smith');
```

   6.4. La/les oficina/es que tenia assignada a Sue Smith passar-la a 'Sense Representant'.

```sql
UPDATE oficina SET director = 999
WHERE director = (SELECT repcod FROM repventa WHERE nombre = 'Sue Smith');
```

   6.5. S'acomiada a Sue Smith.

```sql
DELETE FROM repventa WHERE nombre = 'Sue Smith';
```

## H. Més exercicis

1. Muestra los pedidos que han sido tomados por el mismo representante que contactó por primera vez con el cliente.

```sql
SELECT p.*
FROM pedido p
JOIN cliente c ON p.cliecod = c.cliecod
WHERE p.repcod = c.repcod;
```

2. TOP 5 de los que tienen mejor rendimiento.

```sql
SELECT nombre, ventas, cuota, (ventas / cuota * 100) AS rendiment
FROM repventa
WHERE cuota IS NOT NULL
ORDER BY rendiment DESC
LIMIT 5;
```

3. Mostrar por cada oficina, su mejor vendedor.

```sql
SELECT o.ciudad, r.nombre, r.ventas
FROM repventa r
JOIN oficina o ON r.ofinum = o.ofinum
WHERE r.ventas = (
    SELECT MAX(r2.ventas)
    FROM repventa r2
    WHERE r2.ofinum = r.ofinum
);
```

4. TOP 5 de los que tienen peor rendimiento.

```sql
SELECT nombre, ventas, cuota, (ventas / cuota * 100) AS rendiment
FROM repventa
WHERE cuota IS NOT NULL
ORDER BY rendiment ASC
LIMIT 5;
```

5. Mostrar para cada jefe, cuantos empleados directos tiene a su cargo.

```sql
SELECT j.nombre AS cap, COUNT(r.repcod) AS empleats_directes
FROM repventa r
JOIN repventa j ON r.jefe = j.repcod
GROUP BY j.nombre;
```

## I. Vistes

Creeu una vista anomenada "rendiment" on ha de sortir per a cada representant el seu nom, la ciutat
de l'oficina on treballa i el seu rendiment (el que ha venut sobre el que ha de vendre) expressat com un text, de la següent manera:

* Per sota del 50% (inclòs) >= "Rendiment baix"
* A partir del 50 fins el 75% inclòs => "Rendiment mitjà"
* A partir del 75% fins el 100% => "Rendiment alt"
* A partir del 1800 => "Rendiment excel·lent"

```sql
CREATE VIEW rendiment AS
SELECT
    r.nombre,
    o.ciudad,
    CASE
        WHEN (r.ventas / r.cuota * 100) <= 50  THEN 'Rendiment baix'
        WHEN (r.ventas / r.cuota * 100) <= 75  THEN 'Rendiment mitjà'
        WHEN (r.ventas / r.cuota * 100) < 100  THEN 'Rendiment alt'
        ELSE 'Rendiment excel·lent'
    END AS rendiment
FROM repventa r
JOIN oficina o ON r.ofinum = o.ofinum
WHERE r.cuota IS NOT NULL;
```

## J. Funcions (__funcionsTraining.sql__)

Caldrà veure si cal crear seqüències per les claus primàries.

Per crear una seqüència per una clau primària d'una taula, la podeu inicialitzar a 1. Però com que en el nostre cas ja tenim dades a les taules, és imprescindible fer a continuació el següent (us poso exemple de la taula client):

```
select setval('cliecod_seq', (select max(cliecod) from cliente), true);
```
Aquesta sentència farà que la propera vegada que demanem el següent valor de la seqüència torni max+1, ja que tenim com a tercer paràmetre true [sequence functions](https://www.postgresql.org/docs/current/functions-sequence.html)

`Nota`: Les seqúències s'han de crear __obligatòriament__ fora de les funcions

**Funció**|`existeixClient`
---|---
Paràmetres|p_cliecod  
Tasca|comprova si existeix el client passat com argument  
Retorna|booleà

```sql
CREATE OR REPLACE FUNCTION existeixClient(p_cliecod smallint)
RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM cliente WHERE cliecod = p_cliecod);
END;
$$ LANGUAGE plpgsql;
```

**Funció**|`altaClient`
---|---  
Paràmetres|p_nombre ,p_repcod, p_limcred
Tasca|Donarà d'alta un client
Retorna|Missatge _Client X s'ha donat d'alta correctament_
Nota| si no està creada, creem una seqüència per donar valors a la clau primària. Començarà en el següent valor que hi hagi a la base de dades.

```sql
-- Crear la seqüència FORA de la funció:
CREATE SEQUENCE IF NOT EXISTS cliecod_seq;
SELECT setval('cliecod_seq', (SELECT MAX(cliecod) FROM cliente), true);

CREATE OR REPLACE FUNCTION altaClient(
    p_nombre VARCHAR,
    p_repcod smallint,
    p_limcred numeric
) RETURNS TEXT AS $$
DECLARE
    v_cliecod smallint;
BEGIN
    v_cliecod := nextval('cliecod_seq');
    INSERT INTO cliente (cliecod, nombre, repcod, limcred)
    VALUES (v_cliecod, p_nombre, p_repcod, p_limcred);
    RETURN 'Client ' || p_nombre || ' s''ha donat d''alta correctament';
END;
$$ LANGUAGE plpgsql;
```

**Funció**|`stockOk`
---|---
Paràmetres|p_cant , p_fabcod,p_prodcod
Tasca|Comprova que hi ha prou existències del producte demanat.
Retorna|booleà

```sql
CREATE OR REPLACE FUNCTION stockOk(
    p_cant smallint,
    p_fabcod char(3),
    p_prodcod char(5)
) RETURNS boolean AS $$
DECLARE
    v_exist integer;
BEGIN
    SELECT exist INTO v_exist
    FROM producto
    WHERE fabcod = p_fabcod AND prodcod = p_prodcod;

    RETURN v_exist >= p_cant;
END;
$$ LANGUAGE plpgsql;
```

**Funció**|`altaComanda`
---|---
Paràmetres| Segons els exercicis anteriors i segons necessitat, definiu vosaltres els paràmetres mínims que necessita la funció, tenint en compte que cal contemplar l'opció per defecte de no posar data, amb el què agafarà la data de sistema. Si no hi és, creeu una seqüència per la clau primària de pedido.  
Tasca| Per poder donar d'alta una comanda es tindrà que comprovar que existeix el client i que hi ha prou existències. En aquesta funció heu d'utilitzar les funcions  existeixClient i stockOK (recordeu de no posar `select function(...` ). Evidentment, s'haura de calcular el preu de l'import en funció del preu unitari i de la quantitat d'unitats.  
Retorna|missatge indicant el que ha passat  

```sql
-- Crear la seqüència FORA de la funció:
CREATE SEQUENCE IF NOT EXISTS pednum_seq;
SELECT setval('pednum_seq', (SELECT MAX(pednum) FROM pedido), true);

CREATE OR REPLACE FUNCTION altaComanda(
    p_cliecod smallint,
    p_repcod  smallint,
    p_fabcod  char(3),
    p_prodcod char(5),
    p_cant    smallint,
    p_fecha   date DEFAULT CURRENT_DATE
) RETURNS TEXT AS $$
DECLARE
    v_pednum  integer;
    v_precio  numeric(7,2);
    v_importe numeric(7,2);
BEGIN
    -- Comprovació d'existència del client
    IF NOT existeixClient(p_cliecod) THEN
        RETURN 'Error: el client amb codi ' || p_cliecod || ' no existeix.';
    END IF;

    -- Comprovació d'estoc suficient
    IF NOT stockOk(p_cant, p_fabcod, p_prodcod) THEN
        RETURN 'Error: no hi ha prou existències del producte ' || p_prodcod || ' del fabricant ' || p_fabcod || '.';
    END IF;

    -- Càlcul de l'import
    SELECT precio INTO v_precio
    FROM producto
    WHERE fabcod = p_fabcod AND prodcod = p_prodcod;

    v_importe := v_precio * p_cant;
    v_pednum  := nextval('pednum_seq');

    INSERT INTO pedido (pednum, fecha, cliecod, repcod, fabcod, prodcod, cant, importe)
    VALUES (v_pednum, p_fecha, p_cliecod, p_repcod, p_fabcod, p_prodcod, p_cant, v_importe);

    RETURN 'Comanda ' || v_pednum || ' donada d''alta correctament. Import: ' || v_importe || ' €';
END;
$$ LANGUAGE plpgsql;
```


**Funció**|`preuSenseIVA`
---|---
Paràmetres| p_precio (preu `amb` IVA)
Tasca| Donat un preu amb IVA, es calcularà el preu *sense* IVA (es considera un 21 % d'IVA) i serà retornat.

```sql
CREATE OR REPLACE FUNCTION preuSenseIVA(p_precio numeric)
RETURNS numeric AS $$
BEGIN
    RETURN ROUND(p_precio / 1.21, 2);
END;
$$ LANGUAGE plpgsql;
```

**Funció**|`preuAmbIVA`
---|---
Paràmetres| p_precio (preu `sense` IVA)
Tasca| Donat un preu sense IVA, es calcularà el preu *amb* IVA (es considera un 21 % d'IVA) i serà retornat.

```sql
CREATE OR REPLACE FUNCTION preuAmbIVA(p_precio numeric)
RETURNS numeric AS $$
BEGIN
    RETURN ROUND(p_precio * 1.21, 2);
END;
$$ LANGUAGE plpgsql;
```

# K. Triggers (__triggersTraining.sql__)

1. Implementeu el trigger `tActualitzarVendes` el qual es dispararà quan es fagi una nova comanda. Haurà d'actualitzar els camps calculats vendes de les taules repventa i oficina.

```sql
CREATE OR REPLACE FUNCTION fn_actualitzarVendes()
RETURNS TRIGGER AS $$
BEGIN
    -- Actualitzar vendes del representant
    UPDATE repventa
    SET ventas = ventas + NEW.importe
    WHERE repcod = NEW.repcod;

    -- Actualitzar vendes de l'oficina del representant
    UPDATE oficina
    SET ventas = ventas + NEW.importe
    WHERE ofinum = (SELECT ofinum FROM repventa WHERE repcod = NEW.repcod);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tActualitzarVendes
AFTER INSERT ON pedido
FOR EACH ROW
EXECUTE FUNCTION fn_actualitzarVendes();
```

2. Implementeu el trigger `tControlProducte` per impedir fer qualsevol operació DML sobre la taula pedido fora de l'horari comercial (de dilluns a divendres de 9 a 14 i de 17-20, dissabtes de 10-14h). Proveu la funció to_char amb una data i el patró `d`.

```sql
CREATE OR REPLACE FUNCTION fn_controlProducte()
RETURNS TRIGGER AS $$
DECLARE
    v_dia  integer;       -- 1=Diumenge, 2=Dilluns, ..., 7=Dissabte (format to_char 'd')
    v_hora numeric;       -- hora amb decimals (p.ex. 9.5 = 09:30)
BEGIN
    -- to_char amb patró 'd': 1=diumenge ... 7=dissabte
    v_dia  := to_char(NOW(), 'D')::integer;
    v_hora := EXTRACT(HOUR FROM NOW()) + EXTRACT(MINUTE FROM NOW()) / 60.0;

    -- Dilluns a Divendres (2-6)
    IF v_dia BETWEEN 2 AND 6 THEN
        IF (v_hora >= 9 AND v_hora < 14) OR (v_hora >= 17 AND v_hora < 20) THEN
            RETURN NEW;
        END IF;
    -- Dissabte (7)
    ELSIF v_dia = 7 THEN
        IF v_hora >= 10 AND v_hora < 14 THEN
            RETURN NEW;
        END IF;
    END IF;

    RAISE EXCEPTION 'Operació no permesa fora de l''horari comercial.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tControlProducte
BEFORE INSERT OR UPDATE OR DELETE ON pedido
FOR EACH ROW
EXECUTE FUNCTION fn_controlProducte();
```
