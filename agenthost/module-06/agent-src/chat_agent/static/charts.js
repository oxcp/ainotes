'use strict';
// All labels are text nodes; SVG attributes are fixed names and validated numeric geometry.
const StudioCharts = (() => {
  const colors = ['#38bdf8', '#fbbf24', '#a78bfa', '#4ade80', '#fb7185', '#fb923c'];
  const text = v => typeof v === 'string' && v.length > 0 && [...v].length <= 200;
  function validate(chart) {
    const keys = ['kind', 'title', 'source', 'label_column', 'labels', 'series', 'citations'];
    if (!chart || Object.keys(chart).some(k => !keys.includes(k)) ||
        !['bar', 'line', 'pie', 'table'].includes(chart.kind) ||
        ![chart.title, chart.source, chart.label_column].every(text) ||
        !Array.isArray(chart.labels) || !chart.labels.length || chart.labels.length > 40 ||
        !chart.labels.every(text) || !Array.isArray(chart.series) ||
        !chart.series.length || chart.series.length > 4 ||
        new Set(chart.series.map(s => s?.name)).size !== chart.series.length ||
        !chart.series.every(s => s && Object.keys(s).every(k => ['name', 'values'].includes(k)) &&
          text(s.name) && Array.isArray(s.values) && s.values.length === chart.labels.length &&
          s.values.every(v => typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= 1e15))) {
      throw new Error('INVALID_CHART: Invalid chart data; the text answer is still available.');
    }
    if (chart.kind === 'pie' && (chart.series.length !== 1 ||
        chart.series[0].values.some(v => v < 0) || chart.series[0].values.reduce((a,b) => a+b,0) <= 0)) {
      throw new Error('INVALID_CHART: Pie charts require nonnegative values and a positive total.');
    }
    if (chart.citations !== undefined && (!Array.isArray(chart.citations) || chart.citations.length > 160 ||
        !chart.citations.every(c => c && Object.keys(c).every(k =>
          ['record_id', 'quote', 'filename', 'page_number'].includes(k)) &&
          text(c.record_id) && typeof c.quote === 'string' && c.quote.length > 0 && [...c.quote].length <= 1200 &&
          typeof c.filename === 'string' && c.filename.length > 0 && [...c.filename].length <= 1024 &&
          (c.page_number == null || Number.isInteger(c.page_number))))) {
      throw new Error('INVALID_CHART: Invalid chart citations; the text answer is still available.');
    }
    return chart;
  }
  function element(tag, value, cls) {
    const node = document.createElement(tag);
    if (value !== undefined) node.textContent = value;
    if (cls) node.className = cls;
    return node;
  }
  function svgElement(tag, attrs = {}, value) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [key, val] of Object.entries(attrs)) node.setAttribute(key, String(val));
    if (value !== undefined) node.textContent = value;
    return node;
  }
  const short = s => [...s].length > 16 ? [...s].slice(0, 15).join('') + '…' : s;
  function tooltip(node, value) {
    node.append(svgElement('title', {}, value));
    return node;
  }
  function dataTable(chart) {
    const wrapper = element('div', undefined, 'chart-table-scroll');
    wrapper.tabIndex = 0;
    wrapper.setAttribute('role', 'region');
    wrapper.setAttribute('aria-label', chart.title + ' data table');
    const table = element('table');
    table.append(element('caption', chart.title + ' — chart data'));
    const head = element('thead'), header = element('tr');
    for (const name of [chart.label_column, ...chart.series.map(s => s.name)]) {
      const cell = element('th', name); cell.setAttribute('scope', 'col'); header.append(cell);
    }
    head.append(header); table.append(head);
    const body = element('tbody');
    chart.labels.forEach((label, index) => {
      const row = element('tr'), heading = element('th', label); heading.setAttribute('scope', 'row');
      row.append(heading);
      chart.series.forEach(s => row.append(element('td', String(s.values[index]))));
      body.append(row);
    });
    table.append(body); wrapper.append(table);
    return wrapper;
  }
  function graphic(chart) {
    const svg = svgElement('svg', {viewBox:'0 0 640 360', role:'img',
      'aria-label':chart.title + '. Values in the following data table.'});
    svg.append(svgElement('title', {}, chart.title));
    if (chart.kind === 'pie') {
      const values = chart.series[0].values, total = values.reduce((a,b) => a+b,0);
      let angle = -Math.PI / 2;
      values.forEach((value, i) => {
        if (!value) return;
        const next = angle + value / total * Math.PI * 2;
        const fill = colors[i % colors.length];
        const shape = value === total
          ? svgElement('circle', {cx:320, cy:170, r:140, fill})
          : svgElement('path', {d:`M 320 170 L ${320+140*Math.cos(angle)} ${170+140*Math.sin(angle)} ` +
              `A 140 140 0 ${next-angle > Math.PI ? 1 : 0} 1 ${320+140*Math.cos(next)} ${170+140*Math.sin(next)} Z`,
            fill, stroke:'#0f172a'});
        svg.append(tooltip(shape, `${chart.labels[i]}: ${value} (${(value/total*100).toFixed(1)}% of selected rows)`));
        angle = next;
      });
    } else {
      const values = chart.series.flatMap(s => s.values);
      const low = Math.min(0, ...values), high = Math.max(0, ...values);
      const span = high - low || 1, y = v => 280 - (v-low)/span*245;
      const group = 540/chart.labels.length, x = i => 85+(i+.5)*group;
      for (let i=0; i<=4; i++) {
        const value = low + span*i/4;
        svg.append(svgElement('line', {x1:85, x2:625, y1:y(value), y2:y(value), stroke:'#64748b'}));
        svg.append(tooltip(svgElement('text', {x:80,y:y(value)+4,'text-anchor':'end',fill:'#e2e8f0','font-size':11},
          Number(value.toPrecision(4)).toString()), String(value)));
      }
      svg.append(svgElement('line', {x1:85,x2:625,y1:y(0),y2:y(0),stroke:'#e2e8f0'}));
      chart.labels.forEach((label,i) => {
        // Keep dense axes readable; every label remains available in the table/tooltips.
        if (i % Math.ceil(chart.labels.length/8) === 0) {
          svg.append(tooltip(svgElement('text', {x:x(i),y:300,fill:'#e2e8f0','font-size':11,
            transform:`rotate(20 ${x(i)} 300)`,'text-anchor':'start'}, short(label)), label));
        }
      });
      chart.series.forEach((series, j) => {
        const color = colors[j];
        if (chart.kind === 'line') {
          svg.append(svgElement('polyline', {points:series.values.map((v,i)=>`${x(i)},${y(v)}`).join(' '),
            fill:'none',stroke:color,'stroke-width':2}));
        }
        series.values.forEach((value,i) => {
          const width = group*.8/chart.series.length;
          const shape = chart.kind === 'bar'
            ? svgElement('rect', {x:x(i)-group*.4+j*width,y:Math.min(y(0),y(value)),
              width:width*.9,height:Math.abs(y(value)-y(0)),fill:color})
            : svgElement('circle', {cx:x(i),cy:y(value),r:4,fill:color});
          svg.append(tooltip(shape, `${chart.labels[i]} — ${series.name}: ${value}`));
        });
      });
    }
    return svg;
  }
  function render(container, charts) {
    if (charts === undefined) return; // Older chart-free history.
    try {
      if (!Array.isArray(charts) || charts.length > 4) throw new Error('INVALID_CHART: Too many or invalid charts.');
      charts.forEach(validate);
    } catch (error) {
      const warning = element('p', error.message, 'chart-error'); warning.setAttribute('role', 'alert');
      container.append(warning); return;
    }
    for (const chart of charts) {
      const figure = element('figure', undefined, 'chart');
      figure.append(element('figcaption', chart.title), element('p', chart.source, 'chart-source'));
      if (chart.kind !== 'table') {
        figure.append(graphic(chart));
        const legend = element('ul', undefined, 'chart-legend');
        const names = chart.kind === 'pie' ? chart.labels : chart.series.map(s=>s.name);
        names.forEach((name,i) => {
          const item = element('li'), swatch = svgElement('svg', {viewBox:'0 0 12 12','aria-hidden':'true'});
          swatch.append(svgElement('rect', {width:12,height:12,fill:colors[i%colors.length]}));
          item.append(swatch, element('span', name)); legend.append(item);
        });
        figure.append(legend);
      }
      figure.append(dataTable(chart));
      if (chart.citations?.length) {
        const details = element('details'), list = element('ul');
        details.append(element('summary', 'Chart sources'));
        for (const citation of chart.citations) {
          const page = citation.page_number == null ? '' : ` — page ${citation.page_number}`;
          list.append(element('li', `${citation.filename}${page} [${citation.record_id}]: ${citation.quote}`));
        }
        details.append(list); figure.append(details);
      }
      container.append(figure);
    }
  }
  return {render, validate};
})();
if (typeof module !== 'undefined') module.exports = StudioCharts;
