// records: three-key sort and group-by (SPEC.md)
const N: i64 = 1_000_000;
const M: i64 = 1_000_000_007;

struct Record {
    id: i64,
    dept: i64,
    age: i64,
    salary: i64,
}

fn lcg(x: i64) -> i64 {
    (x * 1103515245 + 12345) % 2147483648
}

fn main() {
    let mut rs: Vec<Record> = Vec::with_capacity(N as usize);
    let mut x: i64 = 42;
    for id in 0..N {
        x = lcg(x);
        rs.push(Record {
            id,
            dept: x % 100,
            age: 18 + (x / 100) % 63,
            salary: 30000 + (x / 6300) % 90000,
        });
    }
    rs.sort_by(|a, b| {
        a.dept
            .cmp(&b.dept)
            .then_with(|| b.age.cmp(&a.age))
            .then_with(|| a.id.cmp(&b.id))
    });
    let mut o: i64 = 0;
    for r in &rs {
        o = (o * 31 + r.id) % M;
    }
    println!("records {} order {}", N, o);
    let mut i = 0;
    while i < rs.len() {
        let dept = rs[i].dept;
        let first = rs[i].id;
        let mut count: i64 = 0;
        let mut sum: i64 = 0;
        while i < rs.len() && rs[i].dept == dept {
            count += 1;
            sum += rs[i].salary;
            i += 1;
        }
        println!("{} {} {} {}", dept, count, sum, first);
    }
}
